# vitellus

vitellus is a native-first rendering hardware interface written in Zig for building game engines and renderers on modern graphics APIs.

Shaders are parsed with SPIR-V and compiled with the [splat](splat) project (spirv-cross packaged for zig).

## add to project
requires zig `0.16.0`

to use this with the zig build system, import as so:
```bash
zig fetch --save git+https://github.com/eggyengine/vitellus
```

and then in `build.zig`:
```zig
const vit = b.dependency("vitellus", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("vitellus", vit.module("vitellus"));
```

Backends can be selected from your dependency options:
```zig
const vit = b.dependency("vitellus", .{
    .target = target,
    .optimize = optimize,
    
    // lazy dependency fetching
    // .vulkan = true,
    // .dx12 = true,
    // .metal = true,
    // .opengl = false,
    // .noop = false,
});
```

If you wish for only the shader compiler `splat`, take a look at the docs at [splat/README.md](splat/README.md). 

and lastly in your library/executable:
```zig
const vit = @import("vitellus");
```

# backend availability

take a look at the current status in [src/backends/README.md](src/backends/README.md)
