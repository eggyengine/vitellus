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

there is a tutorial available in [docs/tutorial](docs/tutorial/README.md) that might be worth checking out

## custom backends

vitellus dispatches every object (instance, adapter, device, queue, ...) through
type-erased vtables, so backends can live entirely outside this repository. to
plug one in (e.g. WebGPU):

1. implement the vtables from `vitellus.hal` (`Instance.VTable`,
   `Adapter.VTable`, `Device.VTable`, ...)
2. expose a `vitellus.BackendFactory` with a unique name and an instance
   constructor
3. pass it via `custom_backends`, which is tried before any built-in backend:

```zig
const instance = try vit.Instance.init(allocator, .{
    .backend = .{ .vulkan = true }, // built-in fallback, or `.{}` for none
    .custom_backends = &.{webgpu.factory},
    .validation = .none,
});
```

custom backends identify themselves in shader compile requests with
`.{ .custom = "webgpu" }` and may return user-defined bytecode formats such as
`.{ .custom = "wgsl" }`.
