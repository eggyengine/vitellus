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

## Built-in modules

| Module | Input | Vulkan | DirectX 12 |
| --- | --- | --- | --- |
| `SPIRVShaderModule` | SPIR-V | Used as is | Needs `enable_spirv_cross` and `enable_dxc` |
| `HLSLShaderModule` | HLSL source | Needs `enable_dxc` (Windows) | Needs `enable_dxc` |
| `BinaryShaderModule` | A finished binary for one backend | Yes | Yes |

### SPIR-V

You can compile SPIR-V offline with any compiler (glslc, Slang, DXC with `-spirv`) and embed it:

```zig
vit.SPIRVShaderModule.init(.{ .code = @embedFile("lighting.frag.spv"), .entry_point = "main" })
```

### HLSL

HLSL is compiled at runtime by DXC. The profile has to match the stage:

```zig
vit.HLSLShaderModule.init(.{ .code = source, .entry_point = "psMain", .profile = .ps_6_7 })
```

### Precompiled binaries

If you ship DXIL or SPIR-V per backend, pick the binary that matches `instance.selected_backend`:

```zig
vit.BinaryShaderModule.init(.{ .backend = .dx12, .format = .dxil, .bytes = @embedFile("lighting.dxil") })
```

## Bindings

Shader bindings have to match your bind group layouts. In GLSL, `layout(set = G, binding = N)` is binding `N` of bind group `G`. In HLSL, the same slot is written `register(xN, spaceG)`.

## Custom modules

A shader module is any value that has a `compile` method:

```zig
const MySlangModule = struct {
    path: []const u8,

    pub fn compile(self: *const MySlangModule, allocator: std.mem.Allocator, request: vit.ShaderCompileRequest) !vit.CompiledShader {
        // request.backend and request.stage tell you what to produce.
        const bytes = try compileWithSlang(allocator, self.path, request);
        return .{ .format = .spirv, .bytes = bytes };
    }
};

const module = vit.ShaderModule.init(MySlangModule{ .path = "shaders/lit.slang" });
```

The module is stored inline, which caps it at 128 bytes, and it must stay valid until `Shader.init` returns. Allocate `bytes` with the allocator you were given, because the backend frees it.
