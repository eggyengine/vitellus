# splat

a shader translation layer written in zig for the needs of `vitellus`.

## backends

- [spirv-cross](https://github.com/KhronosGroup/SPIRV-Cross)
  - spirv ->
    - msl
    - hlsl

## add to project
requires zig `0.16.0`

to use this with the zig build system, import as so:
```bash
zig fetch --save=splat git+https://github.com/eggyengine/vitellus
```

and then in `build.zig`:
```zig
const splat = b.dependency("splat", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("splat", splat.module("splat"));
```

and lastly in your library/executable:
```zig
const splat = @import("splat");
```
