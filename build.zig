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
    var dxc_bin_dir: ?std.Build.LazyPath = null;

    const is_web = target.result.cpu.arch.isWasm();
    const enable_vk = b.option(bool, "vk", "Enable Vulkan backend") orelse !is_web;
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
    shader_options.addOption(bool, "enable_dxc", enable_dxc);
    shader_options.addOption(bool, "enable_spirv_cross", enable_spirv_cross);
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

    // directx shader compiler
    if (enable_dxc and target.result.os.tag == .linux and !target.result.abi.isAndroid()) {
        if (target.result.cpu.arch != .x86_64) @panic("DXC has no prebuilt Linux binary for this architecture");
        if (b.lazyDependency("directx-shader-compiler-linux", .{})) |dep| {
            const lib_dir = dep.path("lib");
            dxc_bin_dir = lib_dir;
            mod.addLibraryPath(lib_dir);
            mod.linkSystemLibrary("dxcompiler", .{});
            // Installed beside the app (zig-out/lib), and found from the package cache when run uncopied.
            mod.addRPathSpecial("$ORIGIN/../lib");
            mod.addRPath(lib_dir);
            // A dependency's install step never runs for the app, so apps install these named
            // paths themselves: zig-out/lib/libdxcompiler.so (and libdxil.so) next to bin/.
            b.addNamedLazyPath("dxcompiler", dep.path("lib/libdxcompiler.so"));
            b.addNamedLazyPath("dxil", dep.path("lib/libdxil.so"));
            b.getInstallStep().dependOn(&b.addInstallFile(dep.path("lib/libdxcompiler.so"), "lib/libdxcompiler.so").step);
            b.getInstallStep().dependOn(&b.addInstallFile(dep.path("lib/libdxil.so"), "lib/libdxil.so").step);
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
            mod.addLibraryPath(dep.path(b.fmt("lib/{s}", .{dxc_arch})));
            mod.linkSystemLibrary("dxcompiler", .{});
            b.addNamedLazyPath("dxcompiler", dep.path(b.fmt("bin/{s}/dxcompiler.dll", .{dxc_arch})));
            b.addNamedLazyPath("dxil", dep.path(b.fmt("bin/{s}/dxil.dll", .{dxc_arch})));
            b.getInstallStep().dependOn(&b.addInstallFile(dep.path(b.fmt("bin/{s}/dxcompiler.dll", .{dxc_arch})), "bin/dxcompiler.dll").step);
            b.getInstallStep().dependOn(&b.addInstallFile(dep.path(b.fmt("bin/{s}/dxil.dll", .{dxc_arch})), "bin/dxil.dll").step);
        }
    }

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
            // For @cImport("spirv_cross_c.h") from vitellus sources.
            mod.addIncludePath(dep.path(""));
            mod.linkLibrary(spirv_cross);
        }
    }

    // vulkan
    if (enable_vk) {
        const vulkan = b.lazyDependency("vulkan", .{
            .registry = b.lazyDependency("vulkan_headers", .{}).?.path("registry/vk.xml"),
        }).?.module("vulkan-zig");
        mod.addImport("vulkan", vulkan);
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

        const run_mod_tests = b.addRunArtifact(mod_tests);
        if (dxc_bin_dir) |dir| run_mod_tests.addPathDir(dir.getPath(b));

        const test_step = b.step("test", "Run tests");
        test_step.dependOn(&run_mod_tests.step);
    }
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
