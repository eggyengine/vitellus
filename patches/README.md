# patches

these patches exist to make android work.

## sdl-android.patch

vitellus reaches SDL3 through [zig-sdl3](https://codeberg.org/7Games/zig-sdl3), which builds SDL from [castholm/SDL](https://github.com/castholm/SDL). that package's `build.zig` only knows desktop targets: an `*-linux-android` target is treated as desktop linux and pulls in X11/Wayland, so it can't produce an SDL that runs inside an APK. the patch teaches it android.

| change | why |
|---|---|
| detect `abi.isAndroid()` as its own platform instead of desktop linux | stops it reaching for X11, Wayland and the other desktop linux dependencies |
| enable the libc feature flags (`HAVE_*`) for android | Bionic has the same headers and functions the desktop builds already assume |
| compile SDL's android sources (`src/core/android`, `src/video/android`, AAudio/OpenSL ES audio, sensors, haptics, HIDAPI joysticks, ...) | the android backend wasn't in the build at all |
| link `android`, `log`, `EGL`, `GLESv1_CM`, `GLESv2`, `OpenSLES`, `aaudio`, `dl` and libc++ | the system libraries those sources call into |
| always build position-independent code | android only loads shared libraries |
| drop the soname version on android | APKs ship plain `libSDL3.so`, so a versioned soname (`libSDL3.so.0`) can't be found at load time |
| add `-pthread` on android like on linux | SDL's thread backend there is pthreads |
| stop adding the host's `/usr/lib` as a library path for macOS sysroot builds | upstream marks it `// ???`; a host path has no business in a cross build |

### how it's applied

nothing patches the fetched package in place. `androidSdl()` in [`build.zig`](../build.zig) copies zig-sdl3's SDL source into a temporary directory, applies the patch, builds it as a shared library against the NDK's libc, and links the resulting `libSDL3.so` into the `sdl3` module in place of the desktop build. the app's APK step packages that same file.

it needs `sh`, `cp` and `patch` on the host, so building for android from a windows host doesn't work yet.

### updating

the patch is pinned to castholm/SDL `v0.4.0+3.4.0` (the hash is in the patch header). when zig-sdl3 bumps SDL, regenerate the patch against the new `build.zig`, or `patch` will reject it.
