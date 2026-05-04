# vitellus

vitellus is a webgpu implementation written in zig, with support for web and native platforms. 

Follows the WebGPU w3 specification. 


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

and lastly in your library/executable:
```zig
const vit = @import("vitellus");
```

## progression
- [ ] vulkan
- [ ] directx
- [ ] metal
- [ ] navigator.gpu
