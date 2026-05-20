> [!INFO]
> currently used as a placeholder in the case anyone implements wgsl shaders. remove when basic implementation completed. 

# splat

a shader translation layer written in zig for the needs of `vitellus`.

## add to project
requires zig `0.16.0`

vitellus already includes splat as a module as `vit.splat`, however to explicitly use splat:

to use this with the zig build system, import as so:
```bash
zig fetch --save git+https://github.com/eggyengine/vitellus
```

and then in `build.zig`:
```zig
const vit = b.dependency("vitellus", .{
    .target = target,
    .optimize = optimize,
    .splat = true,
});

exe.root_module.addImport("splat", vit.module("splat"));
```

and lastly in your library/executable:
```zig
const splat = @import("splat");
```
