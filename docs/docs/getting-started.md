---
sidebar_position: 2
title: Getting started
---

# Getting started

Vitellus requires Zig `0.16.0`.

## Add the dependency

```bash
zig fetch --save git+https://github.com/eggyengine/vitellus
```

Then import the module in `build.zig`:

```zig
const vit = b.dependency("vitellus", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("vitellus", vit.module("vitellus"));
```

And in your code:

```zig
const vit = @import("vitellus");
```

## Build options

| Option | Default | Effect |
| --- | --- | --- |
| `vk` | `true` | Compile the Vulkan backend. |
| `dx12` | `true` | Compile the DirectX 12 backend. This only applies to Windows targets. |
| `enable_dxc` | `false` | Fetch DXC so that `HLSLShaderModule` can compile HLSL at runtime. |
| `enable_spirv_cross` | `false` | Link SPIRV-Cross so that SPIR-V shaders also run on DirectX 12. This also needs `enable_dxc`. |

You pass the options to `b.dependency`:

```zig
const vit = b.dependency("vitellus", .{
    .target = target,
    .optimize = optimize,
    .enable_dxc = true,
    .enable_spirv_cross = true,
});
```

## Windowing

The core module doesn't depend on any windowing library. It takes a `vit.Window`, which is a pair of [candler](https://github.com/eggyengine/candler) display and window handles, so any library that exposes native handles can drive it.

Vitellus ships an adapter for SDL3 in `src/windowing/sdl3.zig`. You build it as a separate module against your own SDL3 dependency, which avoids pulling in a second copy of SDL:

```zig
const sdl3 = b.dependency("sdl3", .{ .target = target, .optimize = optimize });

const vitellus_sdl3 = b.createModule(.{
    .root_source_file = vit.path("src/windowing/sdl3.zig"),
    .target = target,
    .optimize = optimize,
});
vitellus_sdl3.addImport("vitellus", vit.module("vitellus"));
vitellus_sdl3.addImport("sdl3", sdl3.module("sdl3"));

exe.root_module.addImport("vitellus_sdl3", vitellus_sdl3);
```

`Sdl3Window.init(window)` wraps an SDL window, and `asWindow()` returns the `vit.Window` that Vitellus accepts.

## Local commands

```bash
zig build test   # run the tests
zig build check  # type-check without linking
zig build docs   # write the API reference to zig-out/docs
```
