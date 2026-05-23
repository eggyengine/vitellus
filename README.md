# vitellus

vitellus is WebGPU-inspired graphics api written in zig, supporting web and native platforms, and uses the similar concepts as WebGPU.  

Shaders are written in [slang](http://github.com/shader-slang/slang) and primarily used with SPIR-V.

### why not just use sysgpu

albeit [sysgpu](https://code.hexops.org/hexops/mach) is a great project (and hexops' mach project), sysgpu locks you into their own custom version mach-zig version and their ecosystem. vitellus allows you to use any zig version (you always get the most stable version). 

if you do want to use wgsl, you should use sysgpu instead. otherwise if you want write shaders in slang and have more control over your hardware, use vitellus. ~~also, we have a c api~~

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
    // .browser_webgpu = true,
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
