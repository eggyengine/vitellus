# Lesson 4

In this lesson, you will replace the procedural triangle with vertex and index
buffers, then draw several instances with one command.

## Defining the geometry

Use an `extern struct` so its memory layout is suitable for the GPU:

```zig
const Vertex = extern struct {
    position: [2]f32,
    colour: [3]f32,
};

const Instance = extern struct {
    offset: [2]f32,
};

const vertices = [_]Vertex{
    .{ .position = .{ -0.2,  0.2 }, .colour = .{ 1, 0, 0 } },
    .{ .position = .{  0.2,  0.2 }, .colour = .{ 0, 1, 0 } },
    .{ .position = .{  0.2, -0.2 }, .colour = .{ 0, 0, 1 } },
    .{ .position = .{ -0.2, -0.2 }, .colour = .{ 1, 1, 0 } },
};

const indices = [_]u16{ 0, 1, 2, 2, 3, 0 };
const instances = [_]Instance{
    .{ .offset = .{ -0.5, 0.0 } },
    .{ .offset = .{  0.0, 0.0 } },
    .{ .offset = .{  0.5, 0.0 } },
};
```

The index buffer reuses four vertices to build two triangles. The instance
buffer supplies a different offset for each copy of the square.

## Creating the buffers

```zig
const vertex_buffer = try vit.Buffer.init(device, .{
    .size = @sizeOf(@TypeOf(vertices)),
    .usage = .{ .vertex = true },
    .initial_data = std.mem.asBytes(&vertices),
});
defer vertex_buffer.deinit();

const index_buffer = try vit.Buffer.init(device, .{
    .size = @sizeOf(@TypeOf(indices)),
    .usage = .{ .index = true },
    .initial_data = std.mem.asBytes(&indices),
});
defer index_buffer.deinit();

const instance_buffer = try vit.Buffer.init(device, .{
    .size = @sizeOf(@TypeOf(instances)),
    .usage = .{ .vertex = true },
    .initial_data = std.mem.asBytes(&instances),
});
defer instance_buffer.deinit();
```

Device-local buffers use an upload copy during creation when `initial_data` is
present.

## Describing vertex input

Replace the procedural vertex shader with inputs that match the buffers:

```hlsl
struct VertexInput {
    float2 position : TEXCOORD0;
    float3 colour : TEXCOORD1;
    float2 offset : TEXCOORD2;
};

struct VertexOutput {
    float4 position : SV_Position;
    float3 colour : COLOR0;
};

VertexOutput vsMain(VertexInput input) {
    VertexOutput output;
    output.position = float4(input.position + input.offset, 0.0, 1.0);
    output.colour = input.colour;
    return output;
}
```

Add two layouts to the pipeline descriptor:

```zig
const vertex_attributes = [_]vit.hal.pipeline.VertexAttribute{
    .{ .location = 0, .format = .float32x2, .offset = @offsetOf(Vertex, "position") },
    .{ .location = 1, .format = .float32x3, .offset = @offsetOf(Vertex, "colour") },
};
const instance_attributes = [_]vit.hal.pipeline.VertexAttribute{
    .{ .location = 2, .format = .float32x2, .offset = @offsetOf(Instance, "offset") },
};
const vertex_layouts = [_]vit.hal.pipeline.VertexBufferLayout{
    .{ .stride = @sizeOf(Vertex), .attributes = &vertex_attributes },
    .{ .stride = @sizeOf(Instance), .step_mode = .instance, .attributes = &instance_attributes },
};

const pipeline = try vit.GraphicsPipeline.init(device, .{
    // Shader and colour-target fields from Lesson 2...
    .vertex_buffers = &vertex_layouts,
});
```

## Transitioning the buffers

Buffers with `initial_data` are ready in the `common` state after creation. Before
using them as vertex or index input, record their intended states once:

```zig
const setup_commands = try vit.CommandBuffer.init(command_pool);
try setup_commands.barrier(&.{
    .{ .buffer = .{ .buffer = vertex_buffer, .before = .common, .after = .vertex } },
    .{ .buffer = .{ .buffer = instance_buffer, .before = .common, .after = .vertex } },
    .{ .buffer = .{ .buffer = index_buffer, .before = .common, .after = .index } },
});
try setup_commands.finish();
try queue.submit(.{ .command_buffers = &.{setup_commands} });
try queue.waitIdle();
setup_commands.deinit();
```

These transitions are one-time setup work. Do not record `common` to `vertex`
again every frame: after the first transition, the buffers are already in their
new states.

## Drawing indexed instances

Bind both vertex slots and the index buffer before drawing. Consecutive vertex
slots can be set together:

```zig
commands.setGraphicsPipeline(pipeline);
commands.setVertexBuffers(0, &.{
    .{ .buffer = vertex_buffer },
    .{ .buffer = instance_buffer },
});
commands.setIndexBuffer(index_buffer, .uint16, 0);
commands.drawIndexed(@intCast(indices.len), @intCast(instances.len), 0, 0, 0);
```

`drawIndexed` takes index count, instance count, first index, base vertex, and
first instance. This call draws all three squares without duplicating geometry
or recording three draw commands.

Previous: [Lesson 3 — drawing and presenting](lesson-3.md).

Next: [Lesson 5 — bind groups, uniforms, and textures](lesson-5.md).
