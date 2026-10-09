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
// Shader languages are separate modules; add the ones you use (see Shaders).
exe.root_module.addImport("vitellus_spirv", vit.module("vitellus_spirv"));
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
| `enable_dxc` | `false` | Fetch DXC and add the `vitellus_dxc` module, which compiles HLSL at runtime. Supported on Windows and x86_64 Linux. |
| `enable_spirv_cross` | `false` | Link SPIRV-Cross into `vitellus_spirv` so that SPIR-V shaders also run on DirectX 12. This also needs `enable_dxc`. |
| `enable_slang` | `false` | Add the `vitellus_slangc` module, which compiles Slang at runtime. Supported on Windows, Linux and macOS (x86_64 and aarch64). |

You pass the options to `b.dependency`:

```zig
const vit = b.dependency("vitellus", .{
    .target = target,
    .optimize = optimize,
    .enable_dxc = true,
    .enable_spirv_cross = true,
});
```

### Shipping shader compilers with your app

DXC and Slang are shared libraries that Vitellus loads at runtime. A dependency installs into its own prefix, never your app's, so call `installLibraries` from your `build.zig`. It copies every library the enabled options need into `zig-out/lib` (Linux and macOS, found through the rpath Vitellus sets) or `zig-out/bin` (Windows, beside the exe):

```zig
@import("vitellus").installLibraries(b, vit);
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
docs/examples/check.sh  # build the full programs from these guides
```
