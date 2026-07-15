# Lesson 2

In this lesson, you will compile the vertex and fragment shaders and combine
them into a graphics pipeline.

This lesson continues from [Lesson 1](lesson-1.md), so the adapter, device,
graphics queue, and swapchain should already exist.

## writing the shaders

Create `triangle.hlsl` beside your `main.zig` file:

```hlsl
struct VertexOutput {
    float4 position : SV_Position;
    float3 color : COLOR0;
};

VertexOutput vsMain(uint vertex_id : SV_VertexID) {
    const float2 positions[3] = {
        float2( 0.0,  0.6),
        float2( 0.6, -0.6),
        float2(-0.6, -0.6),
    };

    const float3 colors[3] = {
        float3(1.0, 0.1, 0.1),
        float3(0.1, 1.0, 0.1),
        float3(0.1, 0.3, 1.0),
    };

    VertexOutput output;
    output.position = float4(positions[vertex_id], 0.0, 1.0);
    output.color = colors[vertex_id];
    return output;
}

float4 psMain(VertexOutput input) : SV_Target0 {
    return float4(input.color, 1.0);
}
```

The vertex shader uses `SV_VertexID` to select one of three positions. That
keeps this first triangle small: it does not need a vertex buffer yet. The
fragment shader receives the interpolated colour and writes it to the first
colour target.

Embed the file in `main.zig` so it is available when the program starts:

```zig
const shader_source = @embedFile("triangle.hlsl");
```

## creating shader objects

Create one shader for each stage:

```zig
const vertex_shader = try vit.Shader.init(device, .{
    .label = "triangle vertex shader",
    .stage = .vertex,
    .source = vit.HLSLShaderModule.init(.{
        .code = shader_source,
        .entry_point = "vsMain",
        .profile = .vs_6_7,
    }),
});
defer vertex_shader.deinit();

const fragment_shader = try vit.Shader.init(device, .{
    .label = "triangle fragment shader",
    .stage = .fragment,
    .source = vit.HLSLShaderModule.init(.{
        .code = shader_source,
        .entry_point = "psMain",
        .profile = .ps_6_7,
    }),
});
defer fragment_shader.deinit();
```

On DirectX 12, `HLSLShaderModule` compiles these entry points to DXIL through
DXC. Keep `dxcompiler.dll` and `dxil.dll` available beside the executable or on
its DLL search path.

## creating the graphics pipeline

The pipeline combines the shaders with the fixed-function state used for the
draw:

```zig
const color_targets = [_]vit.hal.pipeline.ColorTargetState{
    .{ .format = .bgra8_unorm },
};
const pipeline_layout = try vit.PipelineLayout.init(device, .{});
defer pipeline_layout.deinit();

const pipeline = try vit.GraphicsPipeline.init(device, .{
    .label = "triangle pipeline",
    .vertex = vertex_shader,
    .fragment = fragment_shader,
    .topology = .triangle_list,
    .raster = .{ .cull_mode = .none },
    .color_targets = &color_targets,
    .layout = pipeline_layout,
});
defer pipeline.deinit();
```

The colour-target format must match the swapchain format from Lesson 1. Culling
is disabled so the triangle remains visible regardless of winding while you
are learning the API.

Finally, create storage for the command list that will record each frame:

```zig
const command_pool = try vit.CommandPool.init(device, .{
    .transient = false,
    .reset_individually = true,
});
defer command_pool.deinit();
```

Next: [Lesson 3 — drawing and presenting](lesson-3.md).
