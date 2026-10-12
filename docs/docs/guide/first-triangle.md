---
sidebar_position: 1
title: Your first triangle
---

# Your first triangle

This guide opens an SDL3 window, clears it every frame and draws a triangle. It touches each object you need for presenting a frame. The full program is shown at the end.

It assumes you have already set up the `vitellus`, `vitellus_spirv` and `vitellus_sdl3` modules as described in [Getting started](../getting-started.md).

## 1. Shaders

The `vitellus_spirv` module passes SPIR-V straight to Vulkan. DirectX 12 can use the same SPIR-V if you build with `enable_spirv_cross` and `enable_dxc`, which translate it to HLSL and then compile that to DXIL. The vertex shader reads its positions from a constant array, so you don't need a vertex buffer. In Vitellus, +Y points up in clip space:

```hlsl title="triangle.vert.hlsl"
struct VSOut {
    float4 position : SV_Position;
    float3 color : COLOR0;
};

VSOut main(uint id : SV_VertexID) {
    const float2 positions[3] = { float2(0.0, 0.5), float2(0.5, -0.5), float2(-0.5, -0.5) };
    const float3 colors[3] = { float3(1, 0, 0), float3(0, 1, 0), float3(0, 0, 1) };
    VSOut o;
    o.position = float4(positions[id], 0.0, 1.0);
    o.color = colors[id];
    return o;
}
```

```hlsl title="triangle.frag.hlsl"
float4 main(float3 color : COLOR0) : SV_Target0 {
    return float4(color, 1.0);
}
```

Compile them to SPIR-V next to your `main.zig` so that `@embedFile` can find them. We recommend DXC or Slang:

```bash
# DXC
dxc -spirv -T vs_6_0 -E main triangle.vert.hlsl -Fo triangle.vert.spv
dxc -spirv -T ps_6_0 -E main triangle.frag.hlsl -Fo triangle.frag.spv

# or Slang
slangc triangle.vert.hlsl -target spirv -entry main -stage vertex -o triangle.vert.spv
slangc triangle.frag.hlsl -target spirv -entry main -stage fragment -o triangle.frag.spv
```

Any compiler that emits SPIR-V will work, including glslc if you prefer GLSL.

## 2. Instance, adapter, device and queue

```zig
const instance = try vit.Instance.init(gpa, .{ .validation = .core });
defer instance.deinit();

const adapter = try vit.Adapter.init(instance, .{});
defer adapter.deinit();

const device = try vit.Device.init(adapter, .{});
defer device.deinit();

const queue = try vit.Queue.init(device, .{ .kind = .graphics });
defer queue.deinit();
```

- **`Instance`** loads a backend. `.backend` restricts which backends it may choose from. Leave it unset for the platform default. The `VITELLUS_BACKEND` environment variable can override the order. See [Backends and validation](../concepts/backends.md).
- **`Adapter`** is a physical GPU. Use `instance.enumerateAdapters()` if you want to pick one yourself.
- **`Device`** is the logical device that creates every other object.
- **`Queue`** is where you submit finished command buffers.

Every object has a `deinit`. Release objects in the reverse order you created them, which is the order `defer` already gives you.

## 3. Swapchain

Ask the adapter what the window's surface supports, then create a swapchain that presents through your queue:

```zig
const surface = try window.asWindow();
const caps = try adapter.surfaceCapabilities(gpa, surface);
defer caps.deinit();

const swapchain = try vit.Swapchain.init(adapter, .{
    .window = surface,
    .queue = queue,
    .extent = extent,
    .format = caps.formats[0],
    .present_mode = .fifo, // vsync, available everywhere
    .composite_alpha = caps.composite_alpha[0],
    .image_count = 2,
});
defer swapchain.deinit();
```

`caps.formats` contains `SwapchainFormat` values, but pipelines take a `vit.Format`. The two enums share their tag names, so an `inline else` switch converts one to the other:

```zig
const color_format: vit.Format = switch (caps.formats[0]) {
    inline else => |f| @field(vit.Format, @tagName(f)),
};
```

## 4. Pipeline

```zig
const vs = try vit.Shader.init(device, .{
    .stage = .vertex,
    .source = spirv.SPIRVShaderModule.init(.{ .code = @embedFile("triangle.vert.spv") }),
});
defer vs.deinit();
const fs = try vit.Shader.init(device, .{
    .stage = .fragment,
    .source = spirv.SPIRVShaderModule.init(.{ .code = @embedFile("triangle.frag.spv") }),
});
defer fs.deinit();

const layout = try vit.PipelineLayout.init(device, .{}); // no bind groups
defer layout.deinit();

const pipeline = try vit.GraphicsPipeline.init(device, .{
    .vertex = vs,
    .fragment = fs,
    .layout = layout,
    .raster = .{ .cull_mode = .none },
    .color_targets = &.{.{ .format = color_format }},
});
defer pipeline.deinit();
```

Once the pipeline exists you no longer need the shaders, but keeping them alive until shutdown does no harm.

## 5. The frame

Each frame repeats the same steps:

1. Acquire a swapchain image. The swapchain signals `acquired` when the image is ready.
2. Record a command buffer that moves the image from `present` to `color_attachment`, draws, and then moves it back.
3. Submit the command buffer. The submission waits on `acquired` and signals `render_done`.
4. Present the image. Presentation waits on `render_done`.

```zig
const image = try swapchain.acquireNextImage(acquired);

const cmd = try vit.CommandBuffer.init(pool, .{});
try cmd.barrier(&.{.{ .texture_view = .{ .view = image.view, .before = .present, .after = .color_attachment } }});
try cmd.beginRenderPass(.{ .color_attachments = &.{.{
    .view = image.view,
    .load_op = .clear,
    .clear_value = .{ .r = 0.1, .g = 0.1, .b = 0.12, .a = 1 },
}} });
cmd.setViewport(.{ .width = @floatFromInt(extent.width), .height = @floatFromInt(extent.height) });
cmd.setScissor(.{ .width = extent.width, .height = extent.height });
cmd.setGraphicsPipeline(pipeline);
cmd.draw(3, 1, 0, 0);
cmd.endRenderPass();
try cmd.barrier(&.{.{ .texture_view = .{ .view = image.view, .before = .color_attachment, .after = .present } }});
try cmd.finish();

try queue.submit(.{
    .command_buffers = &.{cmd},
    .wait_semaphores = &.{acquired},
    .signal_semaphores = &.{render_done[image.index]},
});
_ = try swapchain.present(&.{render_done[image.index]});
```

Vitellus never inserts barriers for you. Each resource has to be moved into the state that the next command expects. A swapchain image starts each frame in `present` and has to be back in `present` before you present it.

Keep one `render_done` semaphore per swapchain image. The presentation engine may still be waiting on the semaphore from an earlier frame that used the same image.

## 6. Resizing

Resize the swapchain when the window's pixel size changes. Skip frames while the window has no area, for example while it is minimised:

```zig
if (extent.width != swapchain.info().extent.width or extent.height != swapchain.info().extent.height) {
    try queue.waitIdle();
    try swapchain.resize(extent);
}
```

## Full program

To keep the code short, this version waits for the GPU at the start of every frame. [Synchronisation](../concepts/synchronisation.md) shows how to keep two frames in flight instead.

```zig title="src/main.zig"
const std = @import("std");
const sdl3 = @import("sdl3");
const vit = @import("vitellus");
const spirv = @import("vitellus_spirv");
const vitellus_sdl3 = @import("vitellus_sdl3");

const max_images = 8;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    try sdl3.init(.{ .video = true });
    defer sdl3.quit(.{ .video = true });
    var window = vitellus_sdl3.Sdl3Window.init(try sdl3.video.Window.init(
        "triangle",
        800,
        600,
        .{ .vulkan = true, .resizable = true, .high_pixel_density = true },
    ));
    defer window.deinit();

    const instance = try vit.Instance.init(gpa, .{ .validation = .core });
    defer instance.deinit();
    const adapter = try vit.Adapter.init(instance, .{});
    defer adapter.deinit();
    const device = try vit.Device.init(adapter, .{});
    defer device.deinit();
    const queue = try vit.Queue.init(device, .{ .kind = .graphics });
    defer queue.deinit();

    const surface = try window.asWindow();
    const caps = try adapter.surfaceCapabilities(gpa, surface);
    defer caps.deinit();
    if (caps.formats.len == 0) return error.NoSurfaceFormats;
    const swapchain = try vit.Swapchain.init(adapter, .{
        .window = surface,
        .queue = queue,
        .extent = try pixelSize(window),
        .format = caps.formats[0],
        .present_mode = .fifo,
        .composite_alpha = caps.composite_alpha[0],
    });
    defer swapchain.deinit();
    const color_format: vit.Format = switch (caps.formats[0]) {
        inline else => |f| @field(vit.Format, @tagName(f)),
    };

    const vs = try vit.Shader.init(device, .{
        .stage = .vertex,
        .source = spirv.SPIRVShaderModule.init(.{ .code = @embedFile("triangle.vert.spv") }),
    });
    defer vs.deinit();
    const fs = try vit.Shader.init(device, .{
        .stage = .fragment,
        .source = spirv.SPIRVShaderModule.init(.{ .code = @embedFile("triangle.frag.spv") }),
    });
    defer fs.deinit();
    const layout = try vit.PipelineLayout.init(device, .{});
    defer layout.deinit();
    const pipeline = try vit.GraphicsPipeline.init(device, .{
        .vertex = vs,
        .fragment = fs,
        .layout = layout,
        .raster = .{ .cull_mode = .none },
        .color_targets = &.{.{ .format = color_format }},
    });
    defer pipeline.deinit();

    const pool = try vit.CommandPool.init(device, .{ .kind = .graphics });
    defer pool.deinit();
    const acquired = try vit.Semaphore.init(device, .{});
    defer acquired.deinit();
    var render_done: [max_images]vit.Semaphore = undefined;
    for (&render_done) |*s| s.* = try vit.Semaphore.init(device, .{});
    defer for (render_done) |s| s.deinit();

    var last_cmd: ?vit.CommandBuffer = null;
    defer if (last_cmd) |cmd| cmd.deinit();

    main: while (true) {
        while (sdl3.events.poll()) |event| switch (event) {
            .quit, .window_close_requested => break :main,
            else => {},
        };

        // Wait for the previous frame, so its command buffer and semaphores are free again.
        try queue.waitIdle();
        if (last_cmd) |cmd| cmd.deinit();
        last_cmd = null;
        try pool.reset();

        const extent = try pixelSize(window);
        if (extent.width == 0 or extent.height == 0) {
            sdl3.timer.delayMilliseconds(16); // minimised
            continue;
        }
        const current = swapchain.info().extent;
        if (extent.width != current.width or extent.height != current.height) try swapchain.resize(extent);

        const image = try swapchain.acquireNextImage(acquired);
        if (image.index >= max_images) return error.TooManySwapchainImages;

        const cmd = try vit.CommandBuffer.init(pool, .{});
        last_cmd = cmd;
        try cmd.barrier(&.{.{ .texture_view = .{ .view = image.view, .before = .present, .after = .color_attachment } }});
        try cmd.beginRenderPass(.{ .color_attachments = &.{.{
            .view = image.view,
            .load_op = .clear,
            .clear_value = .{ .r = 0.1, .g = 0.1, .b = 0.12, .a = 1 },
        }} });
        cmd.setViewport(.{ .width = @floatFromInt(extent.width), .height = @floatFromInt(extent.height) });
        cmd.setScissor(.{ .width = extent.width, .height = extent.height });
        cmd.setGraphicsPipeline(pipeline);
        cmd.draw(3, 1, 0, 0);
        cmd.endRenderPass();
        try cmd.barrier(&.{.{ .texture_view = .{ .view = image.view, .before = .color_attachment, .after = .present } }});
        try cmd.finish();

        try queue.submit(.{
            .command_buffers = &.{cmd},
            .wait_semaphores = &.{acquired},
            .signal_semaphores = &.{render_done[image.index]},
        });
        _ = try swapchain.present(&.{render_done[image.index]});
    }
    try queue.waitIdle();
}

fn pixelSize(window: vitellus_sdl3.Sdl3Window) !vit.Extent2D {
    const size = try window.window.getSizeInPixels();
    return .{ .width = @intCast(size.@"0"), .height = @intCast(size.@"1") };
}
```

## Next steps

- [Resources and bindings](../concepts/resources.md): vertex buffers, uniforms and textures.
- [Synchronisation](../concepts/synchronisation.md): frames in flight with a timeline fence.
- [Shaders](../concepts/shaders.md): HLSL, DXC, and translating shaders for DirectX 12.
