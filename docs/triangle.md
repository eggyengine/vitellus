# Drawing a triangle with Vitellus

This tutorial introduces the RHI in the same order used by Vulkan, Direct3D 12,
Metal, and WebGPU: select an adapter, create a device and graphics queue, create
resources and a pipeline, record a command buffer, submit it, and present the
swapchain image.

> The interface is available now. `HLSLShaderModule` uses the pinned DirectX
> Shader Compiler to produce DXIL for DX12 and SPIR-V for Vulkan. DX12 retains
> compiled shader bytecode for later pipeline creation. Pipeline creation and
> the remaining new backend hooks are still stubs and return
> `error.Unsupported`; Metal library compilation is not implemented yet.

## 1. Shader input

`ShaderModule` is a type-erased compilation interface. The selected graphics
backend asks the module to compile for DX12, Vulkan, or Metal and receives an
allocator-owned DXIL, SPIR-V, or Metal library artifact. This keeps compiler
choice outside the RHI: built-in modules can use DXC or Slang, while applications
can provide project-specific shader modules and caching.

Module data is stored inline and borrowed only during `createShader`, so temporary
values such as `HLSLShaderModule.init(...)` are safe. A custom module implements
`compile` and erases itself with `ShaderModule.init`:

```zig
const MyShaderModule = struct {
    source: []const u8,

    pub fn compile(
        self: *const @This(),
        allocator: std.mem.Allocator,
        request: vit.ShaderCompileRequest,
    ) !vit.CompiledShader {
        const output = try myCompiler(allocator, self.source, request.backend, request.stage);
        return .{
            .format = switch (request.backend) {
                .dx12 => .dxil,
                .vulkan => .spirv,
                .metal => .metallib,
            },
            .bytes = output,
            .entry_point = "main",
        };
    }
};

const source = vit.ShaderModule.init(MyShaderModule{ .source = shader_text });
```

For a first triangle, HLSL can generate the positions from `SV_VertexID`, so no
vertex buffer is required:

```zig
const shader_text =
    \\struct VSOut { float4 position : SV_Position; float3 color : COLOR0; };
    \\VSOut vsMain(uint id : SV_VertexID) {
    \\    float2 p[3] = { float2(0, 0.6), float2(0.6, -0.6), float2(-0.6, -0.6) };
    \\    float3 c[3] = { float3(1, 0, 0), float3(0, 1, 0), float3(0, 0, 1) };
    \\    VSOut o; o.position = float4(p[id], 0, 1); o.color = c[id]; return o;
    \\}
    \\float4 psMain(VSOut i) : SV_Target0 { return float4(i.color, 1); }
;

const vertex_shader = try device.createShader(.{
    .label = "triangle vertex",
    .stage = .vertex,
    .source = vit.HLSLShaderModule.init(.{
        .code = shader_text,
        .entry_point = "vsMain",
        .profile = .vs_6_7,
    }),
});
defer device.destroyShader(vertex_shader);

const fragment_shader = try device.createShader(.{
    .label = "triangle fragment",
    .stage = .fragment,
    .source = vit.HLSLShaderModule.init(.{
        .code = shader_text,
        .entry_point = "psMain",
        .profile = .ps_6_7,
    }),
});
defer device.destroyShader(fragment_shader);
```

To supply precompiled code, use `BinaryShaderModule.init` with an explicit
backend and format. Shader stage remains explicit because a binary container may
contain multiple stages or entry points.

## 2. Initialize the GPU objects

After creating an SDL window and adapting it with `vit.windowing.sdl3`, initialize
the RHI objects. Destruction is in reverse creation order.

```zig
const vit = @import("vitellus");

const adapter = try vit.Adapter.init(allocator, .{
    .backend = vit.hal.settings.BackendType.all(),
    .validation = .core,
});
defer adapter.deinit();

const device = try adapter.createDevice();
defer device.deinit();

const queue = try device.createQueue(.{ .kind = .graphics });
defer queue.deinit();

const swapchain = try adapter.createSwapchain(.{
    .window = try sdl_wrapper.asWindow(),
    .queue = queue,
    .format = .bgra8_unorm,
    .present_mode = .fifo,
    .image_count = 2,
});
defer swapchain.deinit();
```

## 3. Create the pipeline and command storage

The pipeline fixes shader stages, primitive assembly, raster state, and attachment
formats together. Its color format must match the swapchain format.

```zig
const targets = [_]vit.hal.pipeline.ColorTargetState{
    .{ .format = .bgra8_unorm },
};
const pipeline = try device.createGraphicsPipeline(.{
    .label = "triangle pipeline",
    .vertex = vertex_shader,
    .fragment = fragment_shader,
    .topology = .triangle_list,
    .raster = .{ .cull_mode = .none },
    .color_targets = &targets,
});
defer device.destroyGraphicsPipeline(pipeline);

const pool = try device.createCommandPool(.{ .transient = true });
defer device.destroyCommandPool(pool);
```

## 4. Record, submit, and present each frame

Acquisition chooses the swapchain image. Commands clear that image, bind the
pipeline, and draw three procedural vertices. A production backend connects
acquire, render, and present with semaphores; empty semaphore lists are useful
for a backend that manages this dependency internally.

```zig
_ = try swapchain.acquireNextImage(null);
const back_buffer = try swapchain.currentTextureView();
const commands = try device.createCommandBuffer(pool);

const colors = [_]vit.hal.command.ColorAttachment{.{
    .view = back_buffer,
    .load_op = .clear,
    .store_op = .store,
    .clear_value = .{ .r = 0.03, .g = 0.04, .b = 0.06, .a = 1.0 },
}};
try commands.beginRenderPass(.{
    .label = "triangle pass",
    .color_attachments = &colors,
});
commands.setPipeline(pipeline);
commands.draw(3, 1, 0, 0);
commands.endRenderPass();
try commands.finish();

const submitted = [_]vit.CommandBuffer{commands};
try queue.submit(.{ .command_buffers = &submitted });
try swapchain.present(&.{});
```

Before resizing or destroying resources that may still be referenced by the GPU,
call `try queue.waitIdle()`. A mature frame loop should use per-frame fences rather
than waiting for the whole GPU every frame.

## Interface map

- `Adapter`: physical GPU discovery and backend selection.
- `Device`: logical GPU and factory for queues, shaders, resources, pipelines,
  and command storage.
- `Queue`: asynchronous submission and completion boundary.
- `Swapchain`: acquire a presentable texture view and present it.
- `CommandBuffer`: record render passes and draw calls.
- `Fence` / `Semaphore`: CPU/GPU completion and GPU/GPU ordering.
- `Buffer` / `Texture` / `TextureView`: storage separated from its interpretation.
- `GraphicsPipeline`: immutable raster pipeline state.
