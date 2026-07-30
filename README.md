# vitellus

vitellus is a native-first rendering hardware interface written in Zig for building game engines and renderers on modern graphics APIs.

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

    .enable_dxc = true, // default is false
    .enable_spirv-cross = true, // default is false
});

exe.root_module.addImport("vitellus", vit.module("vitellus"));
```

and lastly in your library/executable:
```zig
const vit = @import("vitellus");
```

## documentation

~~there is a tutorial available in [docs/tutorial](docs/tutorial/README.md) that might be worth checking out~~