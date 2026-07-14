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
});

exe.root_module.addImport("vitellus", vit.module("vitellus"));
```

Backends can be selected from your dependency options:
```zig
const vit = b.dependency("vitellus", .{
    .target = target,
    .optimize = optimize,
});
```

and lastly in your library/executable:
```zig
const vit = @import("vitellus");
```

## documentation

- [Draw your first triangle](docs/triangle.md)
- Complete example: [`examples/triangle.zig`](examples/triangle.zig) and
  [`examples/triangle.hlsl`](examples/triangle.hlsl). Build it with
  `zig build triangle`.
- Public RHI interfaces live under `vitellus.hal`; commonly used types are also
  re-exported from the package root.
