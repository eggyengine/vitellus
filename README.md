# vitellus

vitellus is a native-first rendering hardware interface written in Zig for building game engines and renderers on modern graphics APIs.

guides and API reference: https://eggyengine.github.io/vitellus/

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

    .enable_dxc = true, // default is false; adds the vitellus_dxc module
    .enable_spirv_cross = true, // default is false
    .enable_slang = true, // default is false; adds the vitellus_slangc module
});

exe.root_module.addImport("vitellus", vit.module("vitellus"));
exe.root_module.addImport("vitellus_spirv", vit.module("vitellus_spirv")); // or vitellus_dxc, vitellus_slangc
@import("vitellus").installLibraries(b, vit); // ships DXC and Slang beside your app
```

and lastly in your library/executable:
```zig
const vit = @import("vitellus");
```