# Lesson 3

In this lesson, you will record the commands that clear the window, draw the
triangle, and present the finished image.

This lesson continues from [Lesson 2](lesson-2.md). The swapchain, pipeline,
and command pool should already exist.

## processing window events

Keep processing SDL events until the user closes the window:

```zig
var quit = false;
while (!quit) {
    while (sdl3.events.poll()) |event| switch (event) {
        .quit, .terminating => quit = true,
        else => {},
    };
    if (quit) break;

    // Record and submit this frame here.
}
```

## acquiring the back buffer

At the start of each frame, acquire the current swapchain image and get the
texture view used as the render target:

```zig
const acquired = try swapchain.acquireNextImage(null);
const back_buffer = acquired.view;
const commands = try vit.CommandBuffer.init(command_pool);
```

The acquired view refers to the swapchain image selected for this frame.

## What `command.barrier` does

A resource barrier tells the GPU that a buffer or texture is changing how it
will be used. It serves two related purposes:

1. **State transition:** the backend changes the native resource state or image
   layout, such as `present` to `color_attachment` on a swapchain image.
2. **Ordering and visibility:** work using the `before` state must complete, and
   its writes must be visible to work using the `after` state.

Vitellus does not guess resource states. The `before` value must describe the
resource's actual current state, and `after` must describe its next use. Record
barriers outside render and compute passes:

```zig
try commands.barrier(&.{.{
    .texture_view = .{
        .view = back_buffer,
        .before = .present,
        .after = .color_attachment,
    },
}});
```

This transition makes the acquired image legal to use as a render target. A
barrier does not copy data, clear a resource, submit work, or wait for the CPU.
It records GPU-side synchronization into the command buffer.

Buffers use the same model. For example, a device-local upload that finishes in
`common` must transition to `vertex` before vertex input reads it. A
`storage_write` to `storage_write` barrier is special: there is no state change,
but it orders unordered-access writes so a later dispatch or draw sees them.

## recording the render pass

Describe how the back buffer should be handled:

```zig
const color_attachments = [_]vit.hal.command.ColorAttachment{.{
    .view = back_buffer,
    .load_op = .clear,
    .store_op = .store,
    .clear_value = .{
        .r = 0.025,
        .g = 0.035,
        .b = 0.055,
        .a = 1.0,
    },
}};
```

`clear` replaces the previous contents with the supplied colour. `store` keeps
the result so the swapchain can present it.

Record the render pass and draw three vertices:

```zig
try commands.beginRenderPass(.{
    .label = "triangle render pass",
    .color_attachments = &color_attachments,
});
commands.setGraphicsPipeline(pipeline);
commands.draw(3, 1, 0, 0);
commands.endRenderPass();
try commands.barrier(&.{.{
    .texture_view = .{
        .view = back_buffer,
        .before = .color_attachment,
        .after = .present,
    },
}});
try commands.finish();
```

The four arguments to `draw` are vertex count, instance count, first vertex,
and first instance. The vertex shader converts vertex IDs `0`, `1`, and `2`
into the three corners defined in `triangle.hlsl`. The final barrier returns the
image to `present`, which is the state required by the swapchain.

## submitting and presenting

Submit the finished command buffer, then present the swapchain image:

```zig
const command_buffers = [_]vit.CommandBuffer{commands};
try queue.submit(.{ .command_buffers = &command_buffers });
_ = try swapchain.present(&.{});
```

Place this directly after the render-pass code inside the event loop. Once the
loop ends, wait for the final GPU work before resources are destroyed:

```zig
try queue.waitIdle();
```

You should now see a red, green, and blue triangle on a dark background. A
complete version is available in [`examples/triangle.zig`](../../examples/triangle.zig)
and [`examples/triangle.hlsl`](../../examples/triangle.hlsl).

Previous: [Lesson 2 — shaders and the graphics pipeline](lesson-2.md).

Next: [Lesson 4 — indexed drawing and instancing](lesson-4.md).
