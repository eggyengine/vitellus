# splat

a shader translation layer written in zig for the needs of `vitellus`.

currently backed by spirv-cross

## backends

- [spirv-cross](https://github.com/KhronosGroup/SPIRV-Cross)
  - spirv ->
    - msl
    - hlsl

## add to project
requires zig `0.16.0`

since `splat` is a submodule for `vitellus`, you are required to save the vitellus package (but not be required to download unnecessary dependencies). 

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

exe.root_module.addImport("splat", vit.module("splat"));
```

and lastly in your library/executable:
```zig
const splat = @import("splat");
```
