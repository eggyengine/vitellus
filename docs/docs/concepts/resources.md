---
sidebar_position: 2
title: Resources and bindings
---

# Resources and bindings

## Buffers

```zig
const vertices = [_]Vertex{ ... };
const vertex_buffer = try vit.Buffer.init(device, .{
    .label = "triangle vertices",
    .size = @sizeOf(@TypeOf(vertices)),
    .usage = .{ .vertex = true },
    .initial_data = std.mem.asBytes(&vertices),
});
defer vertex_buffer.deinit();
```

`.memory` chooses where the buffer is allocated:

| Memory | Use for |
| --- | --- |
| `.device` (default) | Data the GPU reads often. Fill it with `initial_data` or a copy. |
| `.upload` | Data the CPU rewrites, such as per-frame uniforms, or a staging buffer. |
| `.readback` | Results that the GPU copies back for the CPU to read. |

Map an `.upload` or `.readback` buffer to get at its memory:

```zig
const bytes = try uniforms.map(.write, .{ .size = @sizeOf(Transform) });
@memcpy(bytes, std.mem.asBytes(&transform));
uniforms.unmap(.{ .size = @sizeOf(Transform) });
```

### Vertex input

Describe the vertex layout on the pipeline, then bind the buffer before you draw:

```zig
const Vertex = extern struct { position: [3]f32, color: [3]f32 };

const pipeline = try vit.GraphicsPipeline.init(device, .{
    .vertex = vs,
    .fragment = fs,
    .layout = layout,
    .color_targets = &.{.{ .format = color_format }},
    .vertex_buffers = &.{.{ .stride = @sizeOf(Vertex), .attributes = &.{
        .{ .location = 0, .format = .float32x3, .offset = @offsetOf(Vertex, "position") },
        .{ .location = 1, .format = .float32x3, .offset = @offsetOf(Vertex, "color") },
    } }},
});

// while recording:
cmd.setVertexBuffer(0, vertex_buffer, 0);
cmd.setIndexBuffer(index_buffer, .uint16, 0);
cmd.drawIndexed(index_count, 1, 0, 0, 0);
```

## Textures, views and samplers

```zig
const texture = try vit.Texture.init(device, .{
    .width = 256,
    .height = 256,
    .format = .rgba8_unorm,
    .usage = .{ .sampled = true },
    .initial_data = pixels, // tightly packed mip 0
});
const view = try vit.TextureView.init(device, .{ .texture = texture });
const sampler = try vit.Sampler.init(device, .{});
```

You render into a texture through a view as well. Create the texture with `.color_attachment` or `.depth_stencil_attachment` usage, and pass the view to `beginRenderPass`.

## Bind groups

A `BindGroupLayout` declares the slots that a shader reads. A `BindGroup` fills those slots with resources. A `PipelineLayout` lists the bind group layouts in set order.

```zig
const group_layout = try vit.BindGroupLayout.init(device, .{ .entries = &.{
    .{ .binding = 0, .kind = .{ .buffer = .{ .kind = .uniform } }, .visibility = .{ .vertex = true } },
    .{ .binding = 1, .kind = .{ .sampled_texture = .{} }, .visibility = .{ .fragment = true } },
    .{ .binding = 2, .kind = .{ .sampler = .filtering }, .visibility = .{ .fragment = true } },
} });

const group = try vit.BindGroup.init(device, .{
    .layout = group_layout,
    .entries = &.{
        .{ .binding = 0, .resource = .{ .buffer = .{ .buffer = uniforms } } },
        .{ .binding = 1, .resource = .{ .texture_view = view } },
        .{ .binding = 2, .resource = .{ .sampler = sampler } },
    },
});

const layout = try vit.PipelineLayout.init(device, .{ .bind_group_layouts = &.{group_layout} });

// while recording, after setGraphicsPipeline:
cmd.setBindGroup(0, group, &.{});
```

Uniform buffer offsets must be aligned to `adapter.capabilities().limits.min_uniform_buffer_offset_alignment`. That value is 256 on DirectX 12, so 256-byte uniform buffers work everywhere.

## Barriers

Vitellus tracks no resource state, so you write the barriers yourself. Each barrier names the state the resource is in now and the state the next command needs:

```zig
try cmd.barrier(&.{
    .{ .buffer = .{ .buffer = staging_dst, .before = .common, .after = .copy_destination } },
    .{ .texture = .{ .texture = texture, .before = .copy_destination, .after = .sampled } },
    .{ .texture_view = .{ .view = image.view, .before = .present, .after = .color_attachment } },
});
```

Newly created resources start in `.common`. Swapchain images start in `.present`.

## Copies

`copyBuffer`, `copyTexture`, `copyBufferToTexture` and `copyTextureToBuffer` record transfers. A typical upload copies from an `.upload` buffer into a `.device` buffer or texture. To read data back, copy into a `.readback` buffer, wait for the GPU to finish, and then `map(.read, ...)` it.
