---
sidebar_position: 1
title: Backends and validation
---

# Backends and validation

## Choosing a backend

`Instance.init` tries each backend in turn and returns the first one that starts successfully. You can read the backend it picked from `instance.selected_backend`.

```zig
const instance = try vit.Instance.init(gpa, .{
    .backend = .{ .vulkan = true, .dx12 = true }, // null = platform default
    .validation = .none,
});
std.log.info("using {s}", .{instance.selected_backend.name()});
```

The default order depends on the platform:

| Platform | Order |
| --- | --- |
| Windows | DirectX 12, then Vulkan |
| Linux and Android | Vulkan |
| macOS and iOS | Metal (not implemented yet), then Vulkan |

If the `VITELLUS_BACKEND` environment variable is set to `vulkan`, `dx12` or `metal`, that backend is tried first, provided `.backend` allows it. This lets you switch backends without rebuilding:

```bash
VITELLUS_BACKEND=vulkan ./zig-out/bin/my-game
```

## Validation

`.validation` controls the debug layers:

| Level | Meaning |
| --- | --- |
| `.none` | No layers. Use this for release builds. |
| `.core` | Standard API validation. |
| `.extended` | Core validation plus extra checks, such as synchronisation validation. |
| `.gpu_based` | GPU-assisted validation. This is the slowest level and the most thorough. |

A message from a validation layer means the code is wrong, even if the frame looks correct.

## Adapters and capabilities

```zig
const adapter = try vit.Adapter.init(instance, .{});
const info = adapter.info();
std.log.info("GPU: {s}", .{info.nameSlice()});

const caps = adapter.capabilities();
if (!caps.features.timestamp_query) return error.NoTimestamps;

const rgba8 = adapter.formatCapabilities(.rgba8_unorm);
if (!rgba8.usage.storage) return error.NoStorageImages;
```

`instance.enumerateAdapters()` returns every adapter on the selected backend. You own the slice and each adapter in it.

## Custom backends

Each `BackendFactory` in `custom_backends` is tried before the built-in backends. A factory returns an `Instance` whose vtable points at your implementation:

```zig
const instance = try vit.Instance.init(gpa, .{
    .backend = null,
    .validation = .none,
    .custom_backends = &.{.{ .name = "webgpu", .createInstanceFn = createWebGpuInstance }},
});
```

Custom backends can consume their own shader format through `ShaderBinaryFormat.custom`.
