# Backends

Vitellus provides Vulkan and DirectX 12 rendering backends behind the same interface. Vulkan is the Android backend; DirectX 12 is enabled only for Windows targets.

## Build options

The build script accepts `-Dvk=false` to disable Vulkan and `-Ddx12=false` to disable DirectX 12. Runtime HLSL compilation with DXC and SPIRV-Cross translation are optional, controlled by `-Denable_dxc=true` and `-Denable_spirv_cross=true`.

For example:

```sh
zig build test -Dvk=true -Denable_spirv_cross=true
```

The [build script](#file=build.zig&view=source) contains the target guards and dependency wiring. Browse the [Vulkan backend](#file=src%2Fbackends%2Fvulkan.zig) and [DirectX 12 backend](#file=src%2Fbackends%2Fdx12.zig) for implementation details.
