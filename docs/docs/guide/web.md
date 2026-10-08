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

## 2. Pick the backend and shaders

The default backend list on Emscripten is WebGPU, so `.backend = null` works on every platform. If you list backends explicitly, include `.webgpu`:

```zig
const web = @import("builtin").os.tag == .emscripten;
const instance = try vit.Instance.init(gpa, .{
    .backend = if (web) .{ .webgpu = true } else .{ .vulkan = true },
    .validation = .core,
});
```

WebGPU only accepts WGSL. Slang can emit it next to your SPIR-V (`slangc shader.slang -target wgsl -entry vertexMain -stage vertex -o shader.vert.wgsl`). Pass the WGSL as a binary shader module and name the entry point:

```zig
fn shaderSource(code: []const u8, entry_point: []const u8) vit.ShaderModule {
    if (web) return vit.BinaryShaderModule.init(.{
        .backend = .webgpu,
        .format = .wgsl,
        .bytes = code,
        .entry_point = entry_point,
    });
    return vit.SPIRVShaderModule.init(.{ .code = code });
}
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

## 4. Work around Zig 0.16's Emscripten std

Zig 0.16's standard library cannot compile its stderr writer, or `std.Io.Threaded`, for Emscripten. Any code that reaches either one fails to build with errors inside `std/Io/Threaded.zig` or `std/os/emscripten.zig`. Such code includes the default panic handler, the default log function, `std.debug.print`, and zig-sdl3's `main_callbacks`. In your root file, send logs and panics to the browser console instead:

```zig
const web = @import("builtin").os.tag == .emscripten;
extern fn emscripten_console_log(message: [*:0]const u8) void;
extern fn emscripten_console_error(message: [*:0]const u8) void;

pub const std_options: std.Options = if (web) .{ .logFn = consoleLog } else .{};
pub const panic = if (web) std.debug.FullPanic(webPanic) else std.debug.FullPanic(std.debug.defaultPanic);

fn consoleLog(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    var buffer: [1024]u8 = undefined;
    const prefix = "[" ++ @tagName(level) ++ "] " ++ (if (scope == .default) "" else @tagName(scope) ++ ": ");
    const message = std.fmt.bufPrintZ(&buffer, prefix ++ format, args) catch "[log message too long]";
    if (@intFromEnum(level) <= @intFromEnum(std.log.Level.warn)) emscripten_console_error(message) else emscripten_console_log(message);
}

fn webPanic(message: []const u8, _: ?usize) noreturn {
    std.log.err("panic: {s}", .{message});
    @trap();
}
```

If you use zig-sdl3, register the four SDL callbacks yourself on the web and call `SDL_EnterAppMainCallbacks` from an exported `main`, instead of referencing `sdl3.main_callbacks`. Eggy's [`main.zig`](https://github.com/eggyengine/eggy/blob/main/src/main.zig) shows this in full.

## 5. Build and link

Build the app as a static library and link it with `em++`. Emscripten's C++ linker is needed because Dawn's bindings are C++. Zig ships no libc headers for Emscripten, so any C code in the build needs the emsdk sysroot's headers. SDL also reads that sysroot from `--sysroot`:

```zig title="build.zig"
const web = target.result.os.tag == .emscripten;
const emsdk = b.option([]const u8, "emsdk", "Path to emsdk") orelse
    b.graph.environ_map.get("EMSDK") orelse
    b.pathJoin(&.{ b.graph.environ_map.get("HOME") orelse "/", "emsdk" });
const sysroot = b.pathJoin(&.{ emsdk, "upstream/emscripten/cache/sysroot" });
if (web and b.sysroot == null) b.sysroot = sysroot;

const vitellus = b.dependency("vitellus", .{ .target = target, .optimize = optimize, .emsdk = emsdk });
// ... create `app_module` (link_libc = true) and import vitellus as usual ...

if (web) {
    const lib = b.addLibrary(.{ .name = "app", .linkage = .static, .root_module = app_module });
    const emcc = b.addSystemCommand(&.{b.pathJoin(&.{ emsdk, "upstream/emscripten/em++" })});
    emcc.setEnvironmentVariable("EM_CONFIG", b.pathJoin(&.{ emsdk, ".emscripten" }));
    for (lib.getCompileDependencies(false)) |dep| {
        // Every C source (SDL, FreeType, stb, ...) needs Emscripten's libc headers.
        for (dep.root_module.getGraph().modules) |module|
            module.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sysroot, "include" }) });
        // Zig static libraries don't bundle their dependencies, so pass each one.
        if (dep.kind == .lib and dep.linkage == .static) emcc.addArtifactArg(dep);
    }
    emcc.addArgs(&.{
        if (optimize == .Debug) "-O0" else "-O2",
        "--use-port=emdawnwebgpu",
        "-sASYNCIFY", // lets Vitellus wait on WebGPU's async callbacks
        "-sASYNCIFY_STACK_SIZE=65536",
        "-sSTACK_SIZE=1048576",
        "-sALLOW_MEMORY_GROWTH",
        "-o",
    });
    const html = emcc.addOutputFileArg("app.html");
    b.getInstallStep().dependOn(&b.addInstallDirectory(.{
        .source_dir = html.dirname(),
        .install_dir = .prefix,
        .install_subdir = "web",
    }).step);
}
```

Then build:

```bash
zig build -Dtarget=wasm32-emscripten -Doptimize=ReleaseSmall
```

The page is `zig-out/web/app.html`, with `app.js` and `app.wasm` beside it. Pass `--shell-file page.html` to `em++` to use your own page instead of Emscripten's. It needs a `<canvas id="canvas">` and the `{{{ SCRIPT }}}` placeholder.

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
