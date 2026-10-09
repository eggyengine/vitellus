const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const update_submodules = b.addSystemCommand(&.{ "git", "submodule", "update", "--init", "--remote", "--recursive" });
    b.step("update-submodules", "Update submodules to their latest remote commits")
        .dependOn(&update_submodules.step);

    const enable_dx12_requested = b.option(bool, "dx12", "Enable the DirectX 12 backend") orelse true;
    const enable_dx12 = enable_dx12_requested and target.result.os.tag == .windows and !target.result.abi.isAndroid();
    const enable_dxc = b.option(bool, "enable_dxc", "Enable runtime HLSL compilation with DXC") orelse false;
    const enable_spirv_cross =
        b.option(bool, "enable_spirv_cross", "Enable SPIRV-Cross C API shader translation") orelse
        false;
    const enable_slang = b.option(bool, "enable_slang", "Add the vitellus_slangc module for runtime Slang compilation") orelse false;
    var dxc_bin_dir: ?std.Build.LazyPath = null;

    const is_web = target.result.cpu.arch.isWasm();
    const enable_vk = b.option(bool, "vk", "Enable Vulkan backend") orelse !is_web;
    const enable_webgpu = target.result.os.tag == .emscripten;
    // Zig 0.16's self-hosted linker rejects R_X86_64_PC64 in glibc/GCC .sframe.
    const use_llvm = target.result.os.tag == .linux;

    const mod = b.addModule("vitellus", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        // The Vulkan loader and its layers expect the system dynamic linker; without libc,
        // std.DynLib falls back to Zig's own ELF loader and the loader segfaults.
        .link_libc = if (enable_vk and target.result.os.tag != .windows) true else null,
    });
    addDocs(b, mod, "vitellus");
    const shader_options = b.addOptions();
    shader_options.addOption(bool, "enable_dx12", enable_dx12);
    shader_options.addOption(bool, "enable_vk", enable_vk);
    shader_options.addOption(bool, "enable_webgpu", enable_webgpu);
    mod.addOptions("shader_options", shader_options);

    const candler = b.dependency("candler", .{
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("candler", candler.module("candler"));

    // directx
    if (enable_dx12) {
        if (b.lazyDependency("directx-headers", .{})) |dep| {
            mod.addIncludePath(dep.path("include/directx"));
        }
        mod.linkSystemLibrary("dxgi", .{});
        mod.linkSystemLibrary("d3d12", .{});
    }

    // directx shader compiler: the vitellus_dxc module
    const dxc_mod: ?*std.Build.Module = if (enable_dxc) b.addModule("vitellus_dxc", .{
        .root_source_file = b.path("src/dxc/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "vitellus", .module = mod }},
    }) else null;
    if (enable_dxc and target.result.os.tag == .linux and !target.result.abi.isAndroid()) {
        if (target.result.cpu.arch != .x86_64) @panic("DXC has no prebuilt Linux binary for this architecture");
        if (b.lazyDependency("directx-shader-compiler-linux", .{})) |dep| {
            const lib_dir = dep.path("lib");
            dxc_bin_dir = lib_dir;
            dxc_mod.?.addLibraryPath(lib_dir);
            dxc_mod.?.linkSystemLibrary("dxcompiler", .{});
            // Installed beside the app (zig-out/lib), and found from the package cache when run uncopied.
            dxc_mod.?.addRPathSpecial("$ORIGIN/../lib");
            dxc_mod.?.addRPath(lib_dir);
            addRuntimeLibrary(b, dep.path("lib/libdxcompiler.so"), "lib/libdxcompiler.so");
            addRuntimeLibrary(b, dep.path("lib/libdxil.so"), "lib/libdxil.so");
        }
    } else if (enable_dxc) {
        if (target.result.os.tag != .windows) @panic("the bundled DXC dependency supports Windows and x86_64 Linux");
        if (b.lazyDependency("directx-shader-compiler", .{})) |dep| {
            const dxc_arch = switch (target.result.cpu.arch) {
                .x86 => "x86",
                .x86_64 => "x64",
                .aarch64 => "arm64",
                else => @panic("DXC has no prebuilt binary for this Windows architecture"),
            };
            const bin_dir = dep.path(b.fmt("bin/{s}", .{dxc_arch}));
            dxc_bin_dir = bin_dir;
            dxc_mod.?.addLibraryPath(dep.path(b.fmt("lib/{s}", .{dxc_arch})));
            dxc_mod.?.linkSystemLibrary("dxcompiler", .{});
            addRuntimeLibrary(b, dep.path(b.fmt("bin/{s}/dxcompiler.dll", .{dxc_arch})), "bin/dxcompiler.dll");
            addRuntimeLibrary(b, dep.path(b.fmt("bin/{s}/dxil.dll", .{dxc_arch})), "bin/dxil.dll");
        }
    }

    // spir-v: the vitellus_spirv module, translated for DX12 with SPIRV-Cross when enabled
    if (enable_spirv_cross and !enable_dxc) @panic("enable_spirv_cross needs enable_dxc to compile the translated HLSL");
    const spirv_options = b.addOptions();
    spirv_options.addOption(bool, "cross", enable_spirv_cross);
    const spirv_mod = b.addModule("vitellus_spirv", .{
        .root_source_file = b.path("src/spirv/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "vitellus", .module = mod }},
    });
    spirv_mod.addOptions("spirv_options", spirv_options);
    if (dxc_mod) |dxc| spirv_mod.addImport("vitellus_dxc", dxc);

    // SPIRV-Cross C API (https://github.com/KhronosGroup/SPIRV-Cross)
    // Mirrors CMake SPIRV_CROSS_SHARED with GLSL + HLSL + MSL backends enabled.
    // GLSL is required as the base for HLSL/MSL. Exposes spirv_cross_c.h.
    if (enable_spirv_cross) {
        if (b.lazyDependency("spirv-cross", .{})) |dep| {
            const spirv_cross_mod = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libcpp = true,
            });
            spirv_cross_mod.addIncludePath(dep.path(""));
            // Core + GLSL + HLSL + MSL + C wrapper (see CMakeLists.txt spirv-cross-*-sources).
            spirv_cross_mod.addCSourceFiles(.{
                .root = dep.path(""),
                .files = &.{
                    // spirv-cross-core
                    "spirv_cross.cpp",
                    "spirv_parser.cpp",
                    "spirv_cross_parsed_ir.cpp",
                    "spirv_cfg.cpp",
                    // spirv-cross-glsl (required by HLSL/MSL)
                    "spirv_glsl.cpp",
                    // spirv-cross-hlsl / spirv-cross-msl
                    "spirv_hlsl.cpp",
                    "spirv_msl.cpp",
                    // spirv-cross-c
                    "spirv_cross_c.cpp",
                },
                .flags = &.{
                    "-std=c++11",
                    "-DSPIRV_CROSS_C_API_GLSL=1",
                    "-DSPIRV_CROSS_C_API_HLSL=1",
                    "-DSPIRV_CROSS_C_API_MSL=1",
                },
            });

            const spirv_cross = b.addLibrary(.{
                .name = "spirv-cross-c",
                .linkage = .static,
                .root_module = spirv_cross_mod,
            });
            // For @cImport("spirv_cross_c.h").
            spirv_mod.addIncludePath(dep.path(""));
            spirv_mod.linkLibrary(spirv_cross);
        }
    }

    // webgpu, through the emdawnwebgpu port that `emcc --use-port=emdawnwebgpu` downloads
    const emsdk_option = b.option([]const u8, "emsdk", "Path to emsdk for web builds (default: $EMSDK, then ~/emsdk)");
    if (enable_webgpu) {
        const cache = b.pathJoin(&.{ Emscripten.init(b, target, emsdk_option).emsdk, "upstream/emscripten/cache" });
        const port_include = b.pathJoin(&.{ cache, "ports/emdawnwebgpu/emdawnwebgpu_pkg/webgpu/include" });
        const header = b.pathJoin(&.{ port_include, "webgpu/webgpu.h" });
        std.Io.Dir.cwd().access(b.graph.io, header, .{}) catch std.debug.panic(
            "{s} is missing; fetch the port once with `embuilder build emdawnwebgpu`",
            .{header},
        );
        const webgpu_c = b.addTranslateC(.{
            .root_source_file = .{ .cwd_relative = header },
            .target = target,
            .optimize = optimize,
        });
        webgpu_c.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ cache, "sysroot/include" }) });
        mod.addImport("webgpu_c", webgpu_c.createModule());
        mod.link_libc = true;
    }

    // vulkan
    if (enable_vk) {
        const vulkan = b.lazyDependency("vulkan", .{
            .registry = b.lazyDependency("vulkan_headers", .{}).?.path("registry/vk.xml"),
        }).?.module("vulkan-zig");
        mod.addImport("vulkan", vulkan);
    }

    // slang
    if (enable_slang) {
        const slang = if (target.result.os.tag == .emscripten) null else slangPackage(b, target.result);
        const slang_options = b.addOptions();
        slang_options.addOption(bool, "available", slang != null);
        const slangc = b.addModule("vitellus_slangc", .{
            .root_source_file = b.path("src/slangc.zig"),
            .target = target,
            .optimize = optimize,
            // dlopen, unlike Zig's own ELF loader, follows the app's rpath.
            .link_libc = true,
            .imports = &.{.{ .name = "vitellus", .module = mod }},
        });
        slangc.addOptions("slang_options", slang_options);
        if (slang) |dep| {
            const file, const installed = switch (target.result.os.tag) {
                .windows => .{ "bin/slang-compiler.dll", "bin/slang-compiler.dll" },
                .macos => .{ "lib/libslang-compiler.0.2026.18.2.dylib", "lib/libslang-compiler.dylib" },
                else => .{ "lib/libslang-compiler.so", "lib/libslang-compiler.so" },
            };
            switch (target.result.os.tag) {
                .windows => {},
                .macos => slangc.addRPathSpecial("@executable_path/../lib"),
                else => slangc.addRPathSpecial("$ORIGIN/../lib"),
            }
            // Found from the package cache when run uncopied, e.g. by tests.
            if (target.result.os.tag != .windows) slangc.addRPath(dep.path("lib"));
            addRuntimeLibrary(b, dep.path(file), installed);
        }
        const slang_tests = b.addRunArtifact(b.addTest(.{ .root_module = slangc, .use_llvm = use_llvm }));
        if (slang) |dep| if (target.result.os.tag == .windows) slang_tests.addPathDir(dep.path("bin").getPath(b));
        b.step("test-slang", "Run vitellus_slangc tests").dependOn(&slang_tests.step);
    }

    // check step
    // required by zls
    {
        const lib_check = b.addTest(.{
            .name = "vitellus",
            .root_module = mod,
            .use_llvm = use_llvm,
        });
        const check = b.step("check", "Check if vitellus compiles");
        check.dependOn(&lib_check.step);
        for ([_]?*std.Build.Module{ dxc_mod, spirv_mod }) |shader_mod| {
            check.dependOn(&b.addTest(.{ .root_module = shader_mod orelse continue, .use_llvm = use_llvm }).step);
        }
    }

    // tests
    {
        const test_runner: std.Build.Step.Compile.TestRunner = .{
            .path = .{ .cwd_relative = b.graph.zig_lib_directory.join(
                b.allocator,
                &.{ "compiler", "test_runner.zig" },
            ) catch @panic("OOM") },
            .mode = .simple,
        };
        const mod_tests = b.addTest(.{
            .root_module = mod,
            .test_runner = test_runner,
            .use_llvm = use_llvm,
        });

        const test_step = b.step("test", "Run tests");
        test_step.dependOn(&b.addRunArtifact(mod_tests).step);
        for ([_]?*std.Build.Module{ dxc_mod, spirv_mod }) |shader_mod| {
            const run = b.addRunArtifact(b.addTest(.{ .root_module = shader_mod orelse continue, .test_runner = test_runner, .use_llvm = use_llvm }));
            // Windows finds dxcompiler.dll on PATH.
            if (dxc_bin_dir) |dir| run.addPathDir(dir.getPath(b));
            test_step.dependOn(&run.step);
        }
    }
}

/// Web builds with Emscripten. Zig compiles the app into a static library and `em++` links it.
pub const Emscripten = struct {
    emsdk: []const u8,
    /// Emscripten's libc headers; Zig ships none for Emscripten.
    include: std.Build.LazyPath,

    /// `emsdk` defaults to `$EMSDK`, then `~/emsdk`. For an Emscripten `target`, sets `b.sysroot` to
    /// Emscripten's sysroot, which SDL's build reads, so call this before creating dependencies.
    pub fn init(b: *std.Build, target: std.Build.ResolvedTarget, emsdk: ?[]const u8) Emscripten {
        const root = emsdk orelse b.graph.environ_map.get("EMSDK") orelse
            b.pathJoin(&.{ b.graph.environ_map.get("HOME") orelse "/", "emsdk" });
        const sysroot = b.pathJoin(&.{ root, "upstream/emscripten/cache/sysroot" });
        if (target.result.os.tag == .emscripten and b.sysroot == null) b.sysroot = sysroot;
        return .{ .emsdk = root, .include = .{ .cwd_relative = b.pathJoin(&.{ sysroot, "include" }) } };
    }

    pub const AppOptions = struct {
        /// Names the page: `zig-out/web/<name>.html`, with `<name>.js` and `<name>.wasm` beside it.
        name: []const u8,
        /// Exports `main`, as `vitellus_sdl3.main_callbacks` does.
        root_module: *std.Build.Module,
        /// A page with a `<canvas id="canvas">` and the `{{{ SCRIPT }}}` placeholder, instead of Emscripten's.
        shell_file: ?std.Build.LazyPath = null,
        /// Extra `em++` flags.
        args: []const []const u8 = &.{},
    };

    pub const App = struct {
        install: *std.Build.Step.InstallDir,
        /// Serves the installed page with `emrun` and opens it in a browser.
        run: *std.Build.Step.Run,
    };

    /// Links the app, every static library it depends on, and Dawn's WebGPU bindings into a page.
    pub fn addApp(self: Emscripten, b: *std.Build, options: AppOptions) App {
        const lib = b.addLibrary(.{ .name = options.name, .linkage = .static, .root_module = options.root_module });
        // em++, since Dawn's WebGPU bindings are C++.
        const emcc = b.addSystemCommand(&.{b.pathJoin(&.{ self.emsdk, "upstream/emscripten/em++" })});
        emcc.setEnvironmentVariable("EM_CONFIG", b.pathJoin(&.{ self.emsdk, ".emscripten" }));
        for (lib.getCompileDependencies(false)) |dep| {
            // C code in every module (SDL, FreeType, stb, ...) needs Emscripten's libc headers.
            for (dep.root_module.getGraph().modules) |module| module.addSystemIncludePath(self.include);
            // Zig static libraries don't bundle their dependencies, so pass each one.
            if (dep.kind == .lib and dep.linkage == .static) emcc.addArtifactArg(dep);
        }
        emcc.addArgs(&.{
            switch (options.root_module.optimize orelse .Debug) {
                .Debug => "-O0",
                .ReleaseSafe, .ReleaseFast => "-O2",
                .ReleaseSmall => "-Oz",
            },
            "--use-port=emdawnwebgpu",
            // Vitellus waits on WebGPU's async adapter, device and fence callbacks.
            "-sASYNCIFY",
            "-sASYNCIFY_STACK_SIZE=65536",
            "-sSTACK_SIZE=1048576",
            "-sALLOW_MEMORY_GROWTH",
        });
        if (options.shell_file) |shell| {
            emcc.addArg("--shell-file");
            emcc.addFileArg(shell);
        }
        emcc.addArgs(options.args);
        emcc.addArg("-o");
        const html = emcc.addOutputFileArg(b.fmt("{s}.html", .{options.name}));
        const install = b.addInstallDirectory(.{ .source_dir = html.dirname(), .install_dir = .prefix, .install_subdir = "web" });
        b.getInstallStep().dependOn(&install.step);

        const run = b.addSystemCommand(&.{ b.pathJoin(&.{ self.emsdk, "upstream/emscripten/emrun" }), b.getInstallPath(.prefix, b.fmt("web/{s}.html", .{options.name})) });
        run.setEnvironmentVariable("EM_CONFIG", b.pathJoin(&.{ self.emsdk, ".emscripten" }));
        run.step.dependOn(&install.step);
        if (b.args) |args| run.addArgs(args);
        return .{ .install = install, .run = run };
    }
};

/// Installs the shared libraries Vitellus loads at runtime (DXC with `enable_dxc`, Slang with
/// `enable_slang`) beside your app: `zig-out/lib` on Linux and macOS, `zig-out/bin` on Windows.
/// A dependency installs into its own prefix, so call this from your `build.zig`.
pub fn installLibraries(b: *std.Build, vitellus: *std.Build.Dependency) void {
    var it = vitellus.builder.named_lazy_paths.iterator();
    while (it.next()) |entry| {
        if (!std.mem.startsWith(u8, entry.key_ptr.*, runtime_library_prefix)) continue;
        const dest = entry.key_ptr.*[runtime_library_prefix.len..];
        b.getInstallStep().dependOn(&b.addInstallFile(entry.value_ptr.*, dest).step);
    }
}

const runtime_library_prefix = "runtime:";

/// A library loaded at runtime, installed at `dest` (relative to the prefix) by `installLibraries`.
fn addRuntimeLibrary(b: *std.Build, path: std.Build.LazyPath, dest: []const u8) void {
    b.addNamedLazyPath(b.fmt("{s}{s}", .{ runtime_library_prefix, dest }), path);
    b.getInstallStep().dependOn(&b.addInstallFile(path, dest).step);
}

pub const SlangStage = enum { vertex, fragment, compute };

/// Compiles one entry point of a Slang file at build time with the host's `slangc`: to WGSL for
/// Emscripten targets, otherwise to SPIR-V (entry point renamed to `main`). Null until Zig has
/// fetched Slang and rerun `build.zig`.
pub fn compileSlang(b: *std.Build, vitellus: *std.Build.Dependency, target: std.Build.ResolvedTarget, source: std.Build.LazyPath, entry_point: []const u8, stage: SlangStage) ?std.Build.LazyPath {
    const host = b.graph.host.result;
    const slang = slangPackage(vitellus.builder, host) orelse return null;
    const web = target.result.os.tag == .emscripten;
    const run = b.addSystemCommand(&.{slang.path(if (host.os.tag == .windows) "bin/slangc.exe" else "bin/slangc").getPath(b)});
    run.addFileArg(source);
    run.addArgs(&.{ "-target", if (web) "wgsl" else "spirv", "-entry", entry_point, "-stage", @tagName(stage), "-o" });
    return run.addOutputFileArg(b.fmt("{s}.{s}", .{ entry_point, if (web) "wgsl" else "spv" }));
}

fn slangPackage(b: *std.Build, target: std.Target) ?*std.Build.Dependency {
    const name = switch (target.os.tag) {
        .linux => switch (target.cpu.arch) {
            .x86_64 => "slang_linux_x86_64",
            .aarch64 => "slang_linux_aarch64",
            else => @panic("Slang has no release for this Linux architecture"),
        },
        .macos => switch (target.cpu.arch) {
            .x86_64 => "slang_macos_x86_64",
            .aarch64 => "slang_macos_aarch64",
            else => @panic("Slang has no release for this macOS architecture"),
        },
        .windows => switch (target.cpu.arch) {
            .x86_64 => "slang_windows_x86_64",
            .aarch64 => "slang_windows_aarch64",
            else => @panic("Slang has no release for this Windows architecture"),
        },
        else => @panic("Slang has no release for this operating system"),
    };
    return b.lazyDependency(name, .{});
}

pub const AndroidSdl = struct {
    run: *std.Build.Step.Run,
    /// The patched `libSDL3.so` at a fixed install path; package it next to the app with `apk.addLibraryFile`.
    library: std.Build.LazyPath,

    /// The NDK libc file to build with; zig-android-sdk sets it on the app's artifact in `apk.addInstallApk()`.
    pub fn setLibC(self: AndroidSdl, libc_file: std.Build.LazyPath) void {
        self.run.addFileArg(libc_file);
    }
};

/// zig-sdl3 builds castholm/SDL, whose build.zig only knows desktop Linux. For Android, rebuild that
/// same fetched package with `patches/sdl-android.patch` applied and link its `libSDL3.so` into
/// `sdl3_module` instead. `apps` are the shared libraries APKs load; call this once for all of
/// them, before the APKs collect their libraries, then `setLibC`.
pub fn androidSdl(b: *std.Build, vitellus: *std.Build.Dependency, sdl3_module: *std.Build.Module, apps: []const *std.Build.Step.Compile) AndroidSdl {
    const objects = sdl3_module.link_objects.items;
    const index = for (objects, 0..) |object, i| {
        if (object == .other_step and std.mem.eql(u8, object.other_step.name, "SDL3")) break i;
    } else @panic("the sdl3 module does not link zig-sdl3's SDL3 library");
    const desktop = objects[index].other_step;
    // ponytail: needs sh, cp and patch on the host; port to a Zig build tool if Windows hosts build for Android.
    const run = b.addSystemCommand(&.{
        "sh", "-c",
        \\set -e
        \\work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
        \\libc=$(realpath "$7"); cp -R "$1"/. "$work"; chmod -R u+w "$work"; cd "$work"
        \\patch -p1 < "$3"
        \\mkdir .ndk; ln -s "$(sed -n 's/^crt_dir=//p' "$libc")" .ndk/lib # liblog, libandroid, ... live beside the CRT
        \\"$4" build -Dtarget="$5" -Doptimize="$6" -Dpreferred_linkage=dynamic --prefix "$2" --libc "$libc" --search-prefix .ndk
        ,
        "sh",
    });
    run.setName("build patched SDL for Android");
    run.addDirectoryArg(.{ .cwd_relative = desktop.step.owner.build_root.path orelse "." });
    const out = run.addOutputDirectoryArg("sdl");
    run.addFileArg(vitellus.path("patches/sdl-android.patch"));
    run.addArg(b.graph.zig_exe);
    run.addArg(desktop.root_module.resolved_target.?.query.zigTriple(b.allocator) catch @panic("OOM"));
    run.addArg(@tagName(desktop.root_module.optimize orelse .Debug));
    const built = out.path(b, "lib/libSDL3.so");
    objects[index] = .{ .static_path = built };
    // `linkLibrary` also added the desktop build as an include dir; the headers are the same, so drop it.
    for (sdl3_module.include_dirs.items, 0..) |dir, i| {
        if (dir == .other_step and dir.other_step == desktop) {
            _ = sdl3_module.include_dirs.orderedRemove(i);
            break;
        }
    }
    // APK packagers want the file name at configure time, so hand them the installed copy.
    const install = b.addInstallFileWithDir(built, .{ .custom = "android" }, "libSDL3.so");
    for (apps) |app| app.step.dependOn(&install.step);
    return .{ .run = run, .library = .{ .cwd_relative = b.getInstallPath(.{ .custom = "android" }, "libSDL3.so") } };
}

/// `zig build docs`: Zig's HTML API docs for `mod` in zig-out/docs, which
/// .github/workflows/docs.yml publishes to GitHub Pages.
fn addDocs(b: *std.Build, mod: *std.Build.Module, name: []const u8) void {
    const docs = b.addObject(.{ .name = name, .root_module = mod });
    const install = b.addInstallDirectory(.{ .source_dir = docs.getEmittedDocs(), .install_dir = .prefix, .install_subdir = "docs" });
    b.step("docs", "Build the API docs into zig-out/docs").dependOn(&install.step);
}
