# Getting started

Vitellus is a native-first rendering hardware interface for Zig game engines and renderers. It exposes a shared rendering API through `vitellus.hal` and `vitellus` root exports, with Vulkan and DirectX 12 backends selected for the target platform.

Start with the [root module](#file=src%2Froot.zig), then browse the [interface definitions](#file=src%2Finterface%2Fdevice.zig) for device and resource APIs. The API Reference contains Zig signatures and documentation comments; the **Source code** tab shows each complete implementation.

## Add Vitellus to your project

Fetch the package:

```sh
zig fetch --save git+https://github.com/eggyengine/vitellus
```

In your `build.zig`, add the dependency's `vitellus` module to your executable or library, passing your target and optimization level. Import it in Zig with `@import("vitellus")`. See the [repository README](https://github.com/eggyengine/vitellus#add-to-project) for the full build snippet.
