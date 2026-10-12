---
sidebar_position: 2
title: Deploying to the web
---

# Deploying to the web

Vitellus runs in the browser on WebGPU. An app built for `wasm32-emscripten` uses the `webgpu` backend automatically. Zig compiles the app into a static library, and Emscripten links it into a page you can host anywhere.

This guide assumes the app already runs on the desktop, as in [Your first triangle](first-triangle.md).

## 1. Install Emscripten

Install [emsdk](https://emscripten.org/docs/getting_started/downloads.html) and fetch Dawn's WebGPU bindings once:

```bash
git clone https://github.com/emscripten-core/emsdk ~/emsdk
~/emsdk/emsdk install latest
~/emsdk/emsdk activate latest
source ~/emsdk/emsdk_env.sh
embuilder build emdawnwebgpu
```

Vitellus reads `webgpu.h` from that port. It looks for emsdk in `-Demsdk=<path>`, then `$EMSDK`, then `~/emsdk`.

## 2. Shaders

Leave `.backend` unset and Vitellus picks WebGPU on the web. If you list backends yourself, include `.webgpu`: each platform only tries the backends it has, so `.{ .vulkan = true, .webgpu = true }` means Vulkan on the desktop and WebGPU in the browser.

WebGPU only accepts WGSL. Slang can emit it next to your SPIR-V (`slangc shader.slang -target wgsl -entry vertexMain -stage vertex -o shader.vert.wgsl`). Pass it as a binary for the WebGPU backend:

```zig
const module = if (web)
    vit.BinaryShaderModule.init(.{ .backend = .webgpu, .format = .wgsl, .bytes = @embedFile("shader.vert.wgsl"), .entry_point = "vertexMain" })
else
    @import("vitellus_spirv").SPIRVShaderModule.init(.{ .code = @embedFile("shader.vert.spv") });
```

WGSL has no combined image-samplers. Bind the texture and the sampler as separate entries.

## 3. Don't block the browser

The browser owns the main loop. Your app must return from each frame instead of looping forever. SDL's main callbacks (`SDL_AppInit`, `SDL_AppIterate`, ...) already work this way: on the web, SDL calls `SDL_AppIterate` from `requestAnimationFrame`.

WebGPU's adapter, device and completion requests are asynchronous, but Vitellus's API is not. The backend waits on them with `wgpuInstanceWaitAny`, which only works when the app is linked with `-sASYNCIFY` (step 5). Frame pacing comes from the browser, so skip any manual frame limiter or `SDL_Delay` on the web.

A few things behave differently:

- `present` doesn't call into WebGPU. The browser shows the canvas when the frame callback returns, and `present` only releases the frame's texture.
- The only present mode is `.fifo`, and `acquireNextImage` always returns index `0`.
- Canvases are never sRGB. Vitellus still accepts `bgra8_unorm_srgb` and `rgba8_unorm_srgb` swapchains by rendering through an sRGB view of the canvas.
- Barriers, semaphores and command pools are no-ops. WebGPU tracks resource state itself, and its single queue runs work in submission order.
- The backend renders into the page's `#canvas` element. SDL and Emscripten's default page both use it.

## 4. Logging, panics and SDL

Zig 0.16 cannot compile its stderr writer, or `std.Io.Threaded`, for Emscripten. That breaks the default log function, the default panic handler and zig-sdl3's `main_callbacks`. Vitellus has replacements that send logs and panics to the browser console. Off the web they are Zig's and zig-sdl3's defaults, so your root file can use them on every platform:

```zig
pub const std_options = vit.web.std_options;
pub const panic = vit.web.panic;

comptime {
    _ = vitellus_sdl3.main_callbacks; // instead of sdl3.main_callbacks
}
```

Write the same `init`, `iterate`, `event` and `quit` functions as for zig-sdl3. On the web, `Init.gpa` is libc's allocator and `Init.io` is `std.Io.failing`.

## 5. Build and link

Vitellus's `build.zig` exports an `Emscripten` helper. `init` finds emsdk (`-Demsdk`, then `$EMSDK`, then `~/emsdk`) and, for a web target, points `b.sysroot` at Emscripten's sysroot, which SDL's build reads. Call it before creating dependencies. `addApp` links your root module into a page with `em++`:

```zig title="build.zig"
const Emscripten = @import("vitellus").Emscripten;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const emscripten = Emscripten.init(b, target, b.option([]const u8, "emsdk", "Path to emsdk"));
    const vitellus = b.dependency("vitellus", .{ .target = target, .optimize = optimize, .emsdk = emscripten.emsdk });
    // ... create `app_module` (link_libc = true) and import vitellus as usual ...

    if (target.result.os.tag == .emscripten) {
        const app = emscripten.addApp(b, .{ .name = "app", .root_module = app_module });
        b.step("run", "Open the app in a browser").dependOn(&app.run.step);
    } else {
        // b.addExecutable(...) as usual
    }
}
```

`addApp` adds Emscripten's libc headers to every C dependency, passes every static library to `em++`, and sets the flags Vitellus needs (`--use-port=emdawnwebgpu`, `-sASYNCIFY`, ...). Add your own with `.args`, or use your own page with `.shell_file`. The page needs a `<canvas id="canvas">` and the `{{{ SCRIPT }}}` placeholder.

```bash
zig build -Dtarget=wasm32-emscripten -Doptimize=ReleaseSmall
zig build run -Dtarget=wasm32-emscripten   # serves and opens the page with emrun
```

The page is `zig-out/web/app.html`, with `app.js` and `app.wasm` beside it.

## 6. Serve and deploy

Browsers won't load WebAssembly from `file://`, so serve the folder over HTTP to try it:

```bash
python3 -m http.server 8080 --directory zig-out/web
# open http://localhost:8080/app.html
```

The three files are static, so any static host can serve them, including GitHub Pages, Netlify and S3. Two requirements:

- **HTTPS.** WebGPU only exists in secure contexts. `localhost` and `127.0.0.1` count as secure, so testing locally over plain HTTP still works.
- **`application/wasm` for `.wasm` files.** Most hosts already send it. Without it the browser falls back to a slower load path or refuses the file.

## Browser support

WebGPU ships in Chromium-based browsers (Chrome, Edge, Brave). Firefox and Safari enable it on some platforms only. Elsewhere, Firefox users can turn it on with `dom.webgpu.enabled` in `about:config`, plus `gfx.webgpu.ignore-blocklist` if their GPU is blocklisted. When a browser has no WebGPU, `Adapter.init` fails with `error.NoAdapter`, and the console says why.

## Not supported yet

- Readback buffers (`.memory = .readback`) and mapping a buffer for reading
- `resolveTexture` (use a render pass with a `resolve_target` instead)
- GPU-driven draw counts (`drawIndirectCount`, `drawIndexedIndirectCount`)
- Query sets
- Polygon modes other than `.fill`
- Enumerating adapters (`Adapter.enumerate`). A browser exposes one adapter, so use `Adapter.init`.
