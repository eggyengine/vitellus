---
sidebar_position: 4
title: Shaders
---

# Shaders

`Shader.init` takes a `ShaderModule`, which turns your source into a binary for whichever backend is running.

```zig
const shader = try vit.Shader.init(device, .{
    .label = "lighting",
    .stage = .fragment,
    .source = module,
});
```

## Which language

We recommend writing shaders in HLSL, compiled with DXC, or in Slang. Both emit SPIR-V for Vulkan and DXIL for DirectX 12, and Slang also emits WGSL for the [web](../guide/web.md). GLSL works through SPIR-V, but it has no native path to DirectX 12 or WebGPU.

## Shader modules

The core `vitellus` module only takes finished binaries. Each source language is a separate module from the same package, so you only build the compilers you use:

| Module | Type | Input | Vulkan | DirectX 12 | WebGPU |
| --- | --- | --- | --- | --- | --- |
| `vitellus` | `BinaryShaderModule` | A binary for one backend (DXIL, SPIR-V or WGSL) | Yes | Yes | Yes |
| `vitellus_spirv` | `SPIRVShaderModule` | SPIR-V | Used as is | Needs `enable_spirv_cross` and `enable_dxc` | No |
| `vitellus_dxc` | `HLSLShaderModule` | HLSL source | Yes | Yes | No |
| `vitellus_slangc` | `SlangShaderModule` | Slang source | Yes | Yes (Slang loads DXC) | Native only, not in browsers |

`vitellus_dxc` exists with `enable_dxc`, and `vitellus_slangc` with `enable_slang`. Import the ones you need next to `vitellus`:

```zig title="build.zig"
exe.root_module.addImport("vitellus_spirv", vit.module("vitellus_spirv"));
```

### Binaries

`BinaryShaderModule` passes bytes to one backend unchanged. On the web, that's how WGSL goes in:

```zig
vit.BinaryShaderModule.init(.{ .backend = .webgpu, .format = .wgsl, .bytes = @embedFile("lighting.wgsl"), .entry_point = "fragmentMain" })
```

### SPIR-V

Compile SPIR-V offline, preferably with DXC (`-spirv`) or Slang (`-target spirv`), and embed it. Other compilers such as glslc also work:

```zig
@import("vitellus_spirv").SPIRVShaderModule.init(.{ .code = @embedFile("lighting.frag.spv") })
```

### HLSL

`vitellus_dxc` compiles HLSL at runtime with DXC, on Windows and x86_64 Linux. The profile has to match the stage:

```zig
@import("vitellus_dxc").HLSLShaderModule.init(.{ .code = source, .entry_point = "psMain", .profile = .ps_6_7 })
```

### Slang

Slang shaders can be compiled at build time or at runtime.

At build time, `compileSlang` runs the host's `slangc` and gives you a file to embed: WGSL for Emscripten targets, SPIR-V (with the entry point renamed to `main`) everywhere else:

```zig title="build.zig"
const vitellus_build = @import("vitellus");
const vert = vitellus_build.compileSlang(b, vit, target, b.path("shaders/lit.slang"), "vertexMain", .vertex) orelse return;
```

It returns null until Zig has fetched Slang and rerun `build.zig`.

At runtime, build with `enable_slang`, import the `vitellus_slangc` module and call `installLibraries` (see [Getting started](../getting-started.md)). `SlangShaderModule` compiles for whichever backend is running: SPIR-V for Vulkan, DXIL for DirectX 12 (Slang loads DXC for this) and WGSL for WebGPU:

```zig
exe.root_module.addImport("vitellus_slangc", vit.module("vitellus_slangc"));
```

```zig
const slangc = @import("vitellus_slangc");
const module = slangc.SlangShaderModule.init(.{ .code = source, .entry_point = "fragmentMain" });
```

`slangc.compileSource` compiles to a chosen target without a device.

### Precompiled binaries per backend

If you ship DXIL and SPIR-V, pick the binary that matches `instance.selected_backend`:

```zig
vit.BinaryShaderModule.init(.{ .backend = .dx12, .format = .dxil, .bytes = @embedFile("lighting.dxil") })
```

## Bindings

Shader bindings have to match your bind group layouts. In HLSL and Slang, `register(xN, spaceG)` is binding `N` of bind group `G`. In GLSL, the same slot is written `layout(set = G, binding = N)`.

## Custom modules

A shader module is any value that has a `compile` method:

```zig
const MyModule = struct {
    path: []const u8,

    pub fn compile(self: *const MyModule, allocator: std.mem.Allocator, request: vit.ShaderCompileRequest) !vit.CompiledShader {
        // request.backend and request.stage tell you what to produce.
        const bytes = try compileWithMyCompiler(allocator, self.path, request);
        return .{ .format = .spirv, .bytes = bytes };
    }
};

const module = vit.ShaderModule.init(MyModule{ .path = "shaders/lit.shader" });
```

The module is stored inline, which caps it at 128 bytes, and it must stay valid until `Shader.init` returns. Allocate `bytes` with the allocator you were given, because the backend frees it.
