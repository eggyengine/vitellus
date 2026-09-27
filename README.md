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

## android

Vulkan is the Android backend. Zig models Android as `linux` + an Android ABI, so vitellus enables `VK_KHR_android_surface` and loads `libvulkan.so` automatically.

Games should use SDL3 main callbacks (`sdl3.main_callbacks`) so the same binary works on desktop and Android. The bundled `vendor/zig-sdl3` wrapper is the existing zig-sdl3 API; its C SDL is built with the Android video/audio/input drivers.

From an app that depends on vitellus:

```sh
zig build -Dtarget=aarch64-linux-android -Doptimize=ReleaseSafe
```

That produces a shared `libmain.so` suitable for packaging into an APK (see eggy's `build.zig` for the zig-android-sdk APK step).

## documentation

~~there is a tutorial available in [docs/tutorial](docs/tutorial/README.md) that might be worth checking out~~