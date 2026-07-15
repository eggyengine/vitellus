# Lesson 5

In this lesson, you will add a uniform buffer to the indexed draw from Lesson 4
and use it to tint the vertex colours without changing the geometry buffers.

## Declaring the uniform

Bindings are numbered within a bind-group slot. DirectX 12 maps the slot to an
HLSL register space, so binding `0` in bind group `0` is `b0, space0`:

```hlsl
cbuffer Scene : register(b0, space0) {
    float4 tint;
};

float4 psMain(VertexOutput input) : SV_Target0 {
    return float4(input.colour, 1.0) * tint;
}
```

The interpolated per-vertex colour still provides the shape's colour variation.
The uniform applies one tint to the complete draw. Changing `tint` therefore
customises the result without rebuilding the vertex or index buffer.

## Creating the binding layout

A bind-group layout describes what type of resource occupies each binding and
which shader stages can access it:

```zig
const scene_layout = try device.createBindGroupLayout(.{
    .label = "scene layout",
    .entries = &.{.{
        .binding = 0,
        .kind = .{ .buffer = .{
            .kind = .uniform,
            .min_size = @sizeOf([4]f32),
        } },
        .visibility = .{ .fragment = true },
    }},
});
defer device.destroyBindGroupLayout(scene_layout);
```

Include that layout in the pipeline layout, then pass the pipeline layout to the
graphics pipeline:

```zig
const pipeline_layout = try device.createPipelineLayout(.{
    .bind_group_layouts = &.{scene_layout},
});
defer device.destroyPipelineLayout(pipeline_layout);

const pipeline = try device.createGraphicsPipeline(.{
    // Shader, vertex-buffer, and colour-target fields from Lesson 4...
    .layout = pipeline_layout,
});
defer device.destroyGraphicsPipeline(pipeline);
```

The position of `scene_layout` in `bind_group_layouts` is the slot later passed
to `setBindGroup`. Here it is slot `0`.

## Creating the uniform buffer

DirectX 12 constant-buffer views require a 256-byte-aligned size. Reserve 256
bytes even though the shader reads only one 16-byte `float4`:

```zig
const tint = [4]f32{ 0.45, 0.85, 1.0, 1.0 };
const uniform_buffer = try device.createBuffer(.{
    .label = "scene uniform",
    .size = 256,
    .usage = .{ .uniform = true },
    .memory = .upload,
    .initial_data = std.mem.asBytes(&tint),
});
defer device.destroyBuffer(uniform_buffer);
```

The RGB values multiply the red, green, and blue vertex channels; alpha
multiplies opacity. Try values such as `{ 1.0, 0.4, 0.4, 1.0 }` for a red tint or
`{ 0.4, 1.0, 0.5, 1.0 }` for a green tint.

Upload memory remains CPU-writable and in a shader-readable DX12 state, so this
buffer does not need the one-time device-local transition used by the vertex
and index buffers.

## Creating and binding the group

Create a bind group that assigns the uniform buffer to binding `0`:

```zig
const scene_group = try device.createBindGroup(.{
    .label = "scene resources",
    .layout = scene_layout,
    .entries = &.{.{
        .binding = 0,
        .resource = .{ .buffer = .{
            .buffer = uniform_buffer,
            .size = 256,
        } },
    }},
});
defer device.destroyBindGroup(scene_group);
```

Bind the group after the matching pipeline and before the indexed draw:

```zig
commands.setGraphicsPipeline(pipeline);
commands.setVertexBuffers(0, &.{
    .{ .buffer = vertex_buffer },
    .{ .buffer = instance_buffer },
});
commands.setIndexBuffer(index_buffer, .uint16, 0);
commands.setBindGroup(0, scene_group, &.{});
commands.drawIndexed(@intCast(indices.len), @intCast(instances.len), 0, 0, 0);
```

The final `&.{}` contains dynamic buffer offsets. This layout does not declare a
dynamic uniform, so the slice must be empty.

Keep the bind-group layout, bind group, uniform buffer, and pipeline layout alive
until all submitted command buffers that use them have finished.

A complete indexed and uniform-tinted version is available in
[`examples/triangle.zig`](../../examples/triangle.zig) and
[`examples/triangle.hlsl`](../../examples/triangle.hlsl).

Previous: [Lesson 4 — indexed drawing and instancing](lesson-4.md).
